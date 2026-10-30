/// A CD drive that can read audio sectors. Hardware drives and `SimulatedDrive` conform to it.
public protocol CDDrive {
    func readTOC() throws -> TOC

    /// Reads raw audio sectors, 2352 bytes each. The data is not offset-corrected.
    func readAudioSectors(at lba: Int, count: Int) throws -> [UInt8]

    /// Reads the Q subchannel of `count` sectors. Frames can be damaged; check `isValid`.
    func readQSubchannel(at lba: Int, count: Int) throws -> [QSubchannel]

    /// Reads raw audio sectors with their C2 error flags: 294 bytes for each sector,
    /// one bit for each of its 2352 bytes (the first byte at bit 7), set where the drive
    /// could not correct the data. The flags are a hint only: on damaged discs they
    /// change from read to read.
    func readAudioSectorsWithC2(at lba: Int, count: Int) throws -> (audio: [UInt8], errorFlags: [UInt8])

    /// Reads raw audio sectors with their C2 error flags if `c2` (empty if not), and their Q
    /// subchannel frames if `q` (empty if not). A drive reads them in one command, which costs
    /// no more time than the audio alone on the drives tested (MATSHITA, ASUS, 2026-10-26).
    func readAudioSectors(at lba: Int, count: Int, c2: Bool, q: Bool) throws -> SectorRead

    /// Reads the disc's CD-Text, as the drive gives it (see `CDText`). Nil if the disc has none.
    func readCDText() throws -> [UInt8]?

    /// What the disc is: pressed, or written in a drive (CD-R or CD-RW). Nil if the drive cannot tell.
    func readMediaType() throws -> DiscMediaType?

    /// Reads the raw P–W subchannel of `count` audio sectors, 96 bytes each (one bit of each
    /// channel in each byte: P is bit 7, Q bit 6, R to W bits 5 to 0), for CD+G graphics.
    /// Not every drive gives it: the HL-DT-ST BU50N refuses it, and the MATSHITA gave garbage
    /// on a damaged disc (2026-10-29), so a failure means only that this drive cannot tell.
    func readSubchannelPW(at lba: Int, count: Int) throws -> [UInt8]

    /// The mode of the data sector at `lba`, from its header.
    func readDataMode(at lba: Int) throws -> DataSectorMode

    /// Reads the 2048 bytes of user data of `count` data sectors of `mode` (Mode 1, or Mode 2
    /// Form 1), as an ISO image holds them. The drive corrects them with their own error
    /// correction, and fails a sector it cannot correct.
    func readDataSectors(at lba: Int, count: Int, mode: DataSectorMode) throws -> [UInt8]
}

/// The kind of a data sector, from its header: Mode 1, or Mode 2 (CD-ROM XA) Form 1 or Form 2.
/// Mode 1 and Mode 2 Form 1 hold 2048 bytes of user data, with error correction.
public enum DataSectorMode: String, Codable, Sendable, CustomStringConvertible {
    case mode1
    case mode2Form1
    case mode2Form2

    public var description: String {
        switch self {
        case .mode1: "Mode 1"
        case .mode2Form1: "Mode 2 Form 1"
        case .mode2Form2: "Mode 2 Form 2"
        }
    }
}

/// Sectors from `CDDrive.readAudioSectors(at:count:c2:q:)`.
public struct SectorRead: Sendable {
    public var audio: [UInt8]
    public var errorFlags: [UInt8]
    public var q: [QSubchannel]

    public init(audio: [UInt8], errorFlags: [UInt8] = [], q: [QSubchannel] = []) {
        self.audio = audio
        self.errorFlags = errorFlags
        self.q = q
    }
}

extension CDDrive {
    /// Reads the audio, the C2 flags, and the Q frames one after the other.
    public func readAudioSectors(at lba: Int, count: Int, c2: Bool, q: Bool) throws -> SectorRead {
        let (audio, flags) =
            c2 ? try readAudioSectorsWithC2(at: lba, count: count) : (try readAudioSectors(at: lba, count: count), [])
        return SectorRead(audio: audio, errorFlags: flags, q: q ? try readQSubchannel(at: lba, count: count) : [])
    }

    /// Reads the Q subchannel of one sector.
    public func readQSubchannel(at lba: Int) throws -> QSubchannel {
        try readQSubchannel(at: lba, count: 1)[0]
    }

    public func readMediaType() throws -> DiscMediaType? { nil }

    /// A drive that cannot read the raw subchannel fails every read of it.
    public func readSubchannelPW(at lba: Int, count: Int) throws -> [UInt8] { throw DriveError.readFailed(lba: lba) }

    /// A drive that cannot read data sectors fails every read of one.
    public func readDataMode(at lba: Int) throws -> DataSectorMode { throw DriveError.readFailed(lba: lba) }
    public func readDataSectors(at lba: Int, count: Int, mode: DataSectorMode) throws -> [UInt8] {
        throw DriveError.readFailed(lba: lba)
    }
}

/// What a disc is made of: pressed in a factory, or written by a drive. A pressed disc is
/// what AccurateRip and CTDB know; a CD-R copy of it reads the same, but a CD-R of a show
/// or a mix is in neither database, which the rip report should explain.
public enum DiscMediaType: String, Codable, Sendable, CustomStringConvertible {
    case pressed
    case recordable
    case rewritable

    public var description: String {
        switch self {
        case .pressed: "pressed CD"
        case .recordable: "CD-R"
        case .rewritable: "CD-RW"
        }
    }
}

public enum DriveError: Error, Equatable, CustomStringConvertible {
    case sectorOutOfRange(lba: Int)
    case readFailed(lba: Int)
    /// The drive cannot read the TOC. After many failed reads, a drive can stay in this state.
    case tocUnreadable

    public var description: String {
        switch self {
        case .sectorOutOfRange(let lba): "Sector \(lba) is outside the disc"
        case .readFailed(let lba): "Cannot read sector \(lba)"
        case .tocUnreadable: "The drive cannot read the disc's TOC. Eject the disc and insert it again."
        }
    }
}
