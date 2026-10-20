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
    public static func position(track: Int, index: Int, lba: Int) -> QSubchannel {
        func bcd(_ value: Int) -> UInt8 { UInt8((value / 10) << 4 | value % 10) }
        let msf = lba + CDDA.leadInSectors
        let seconds = msf / CDDA.sectorsPerSecond
        var bytes: [UInt8] = [
            0x01, track == leadOutTrack ? 0xAA : bcd(track), bcd(index), 0, 0, 0, 0,
            bcd(seconds / 60), bcd(seconds % 60), bcd(msf % CDDA.sectorsPerSecond),
        ]
        let crc = crc(bytes[...])
        bytes += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        return QSubchannel(bytes: bytes)
    }

    public var control: UInt8 { bytes[0] >> 4 }
    public var adr: UInt8 { bytes[0] & 0x0F }

    public var isValid: Bool {
        Self.crc(bytes[0..<10]) == UInt16(bytes[10]) << 8 | UInt16(bytes[11])
    }

    /// The position in a valid ADR 1 frame. Nil for other frames (such as MCN and ISRC) and damaged frames.
    public var position: Position? {
        guard isValid, adr == 1 else { return nil }
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
