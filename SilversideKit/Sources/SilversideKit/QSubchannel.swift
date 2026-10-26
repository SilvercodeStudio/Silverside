/// One Q subchannel frame: control and ADR, 9 data bytes, and a CRC.
public struct QSubchannel: Equatable, Sendable {
    /// The track, index, and absolute position from an ADR 1 frame.
    public struct Position: Equatable, Sendable {
        /// The track number, or `QSubchannel.leadOutTrack` in the lead-out.
        public var track: Int
        public var index: Int
        public var lba: Int
    }

    public static let byteCount = 12
    public static let leadOutTrack = 0xAA

    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        precondition(bytes.count == Self.byteCount)
        self.bytes = bytes
    }

    /// Makes a valid ADR 1 frame for an audio sector, with the relative time left at zero.
    /// `control` is the 4 control bits (see `Control`).
    public static func position(track: Int, index: Int, lba: Int, control: UInt8 = 0) -> QSubchannel {
        func bcd(_ value: Int) -> UInt8 { UInt8((value / 10) << 4 | value % 10) }
        let msf = lba + CDDA.leadInSectors
        let seconds = msf / CDDA.sectorsPerSecond
        return withCRC([
            control << 4 | 0x01, track == leadOutTrack ? 0xAA : bcd(track), bcd(index), 0, 0, 0, 0,
            bcd(seconds / 60), bcd(seconds % 60), bcd(msf % CDDA.sectorsPerSecond),
        ])
    }

    /// Makes a valid ADR 2 frame. `mcn` must be 13 digits.
    public static func mcn(_ mcn: String) -> QSubchannel {
        let digits = mcn.compactMap(\.wholeNumberValue).map(UInt8.init) + [0]
        precondition(digits.count == 14)
        let packed = stride(from: 0, to: 14, by: 2).map { digits[$0] << 4 | digits[$0 + 1] }
        return withCRC([0x02] + packed + [0, 0])
    }

    /// Makes a valid ADR 3 frame. `isrc` must be 5 letters or digits and then 7 digits.
    public static func isrc(_ isrc: String) -> QSubchannel {
        let characters = Array(isrc)
        precondition(characters.count == 12)
        let code = characters[0..<5].reduce(UInt32(0)) { $0 << 6 | UInt32(isrcCodes.firstIndex(of: $1)!) } << 2
        let digits = characters[5...].compactMap(\.wholeNumberValue).map(UInt8.init) + [0]
        let packed = stride(from: 0, to: 8, by: 2).map { digits[$0] << 4 | digits[$0 + 1] }
        let codeBytes = (0..<4).map { UInt8(truncatingIfNeeded: code >> (24 - 8 * $0)) }
        return withCRC([0x03] + codeBytes + packed + [0])
    }

    private static func withCRC(_ bytes: [UInt8]) -> QSubchannel {
        let crc = crc(bytes[...])
        return QSubchannel(bytes: bytes + [UInt8(crc >> 8), UInt8(crc & 0xFF)])
    }

    /// The 6-bit character codes of an ISRC's first five characters. "?" marks unused codes.
    private static let isrcCodes = Array("0123456789???????ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// The control bits, as in the TOC: 1 pre-emphasis, 2 digital copy permitted, 4 data, 8 four-channel audio.
    public var control: UInt8 { bytes[0] >> 4 }
    public var adr: UInt8 { bytes[0] & 0x0F }

    public var isValid: Bool {
        Self.crc(bytes[0..<10]) == UInt16(bytes[10]) << 8 | UInt16(bytes[11])
    }

    /// The position in a valid ADR 1 frame. Nil for other frames (such as MCN and ISRC) and damaged frames.
    public var position: Position? {
        isValid ? unverifiedPosition : nil
    }

    /// The position in an ADR 1 frame, without the CRC check. Use it only with
    /// another check, such as an absolute time that agrees with the sector read.
    public var unverifiedPosition: Position? {
        guard adr == 1 else { return nil }
        func bcd(_ byte: UInt8) -> Int? {
            byte >> 4 <= 9 && byte & 0x0F <= 9 ? Int(byte >> 4) * 10 + Int(byte & 0x0F) : nil
        }
        let track = bytes[1] == 0xAA ? Self.leadOutTrack : bcd(bytes[1])
        guard let track, let index = bcd(bytes[2]), let minute = bcd(bytes[7]), let second = bcd(bytes[8]),
            let frame = bcd(bytes[9])
        else { return nil }
        let lba = (minute * 60 + second) * CDDA.sectorsPerSecond + frame - CDDA.leadInSectors
        return Position(track: track, index: index, lba: lba)
    }

    /// The Media Catalog Number (13 digits) in a valid ADR 2 frame.
    public var mcn: String? {
        guard isValid, adr == 2 else { return nil }
        let digits = bytes[1...7].flatMap { [$0 >> 4, $0 & 0x0F] }.prefix(13)
        guard digits.allSatisfy({ $0 <= 9 }) else { return nil }
        return String(digits.map { Character(String($0)) })
    }

    /// The ISRC in a valid ADR 3 frame: 5 characters from 6-bit codes, then 7 BCD digits.
    public var isrc: String? {
        guard isValid, adr == 3 else { return nil }
        let code = bytes[1...4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let characters = (0..<5).map { Int(code >> (26 - 6 * $0) & 0x3F) }
        guard characters.allSatisfy({ Self.isrcCodes.indices.contains($0) && Self.isrcCodes[$0] != "?" }) else {
            return nil
        }
        let digits = bytes[5...8].flatMap { [$0 >> 4, $0 & 0x0F] }.prefix(7)
        guard digits.allSatisfy({ $0 <= 9 }) else { return nil }
        return String(characters.map { Self.isrcCodes[$0] }) + String(digits.map { Character(String($0)) })
    }

    /// CRC-16/CCITT with the bits inverted, as the Q subchannel stores it.
    private static func crc(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? crc << 1 ^ 0x1021 : crc << 1
            }
        }
        return ~crc
    }
}

/// The control bits of a track's Q frames: how many valid frames of the track were read, and
/// how many had each bit. A pressed disc can set a bit here and not in the TOC: the *Denon
/// Audio Technical CD* has pre-emphasis in the Q frames of 23 tracks and in none of its TOC entries.
public struct SubchannelControl: Codable, Equatable, Sendable {
    public var frames = 0
    public var preEmphasis = 0
    public var copyPermitted = 0
    public var data = 0
    public var fourChannel = 0

    public init() {}

    /// Counts the valid position frames of `track` among `frames`. Frames of other tracks
    /// (the next track's pregap, a read's margins) and MCN and ISRC frames are left out.
    public mutating func add(_ frames: some Sequence<QSubchannel>, track: Int) {
        for frame in frames where frame.position?.track == track {
            self.frames += 1
            if frame.control & 0x01 != 0 { preEmphasis += 1 }
            if frame.control & 0x02 != 0 { copyPermitted += 1 }
            if frame.control & 0x04 != 0 { data += 1 }
            if frame.control & 0x08 != 0 { fourChannel += 1 }
        }
    }

    /// True if most frames have pre-emphasis. A frame whose CRC passes can still be wrong, so one frame does not decide.
    public var hasPreEmphasis: Bool { preEmphasis * 2 > frames }
    public var isCopyPermitted: Bool { copyPermitted * 2 > frames }
    public var isFourChannel: Bool { fourChannel * 2 > frames }

    /// True if the frames disagree on a bit: some have it and some do not.
    public var isMixed: Bool {
        [preEmphasis, copyPermitted, data, fourChannel].contains { $0 > 0 && $0 < frames }
    }
}
