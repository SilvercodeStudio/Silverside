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

    /// Reads the disc's CD-Text, as the drive gives it (see `CDText`). Nil if the disc has none.
    func readCDText() throws -> [UInt8]?

    /// What the disc is: pressed, or written in a drive (CD-R or CD-RW). Nil if the drive cannot tell.
    func readMediaType() throws -> DiscMediaType?
}

extension CDDrive {
    /// Reads the Q subchannel of one sector.
    public func readQSubchannel(at lba: Int) throws -> QSubchannel {
        try readQSubchannel(at: lba, count: 1)[0]
    }

    public func readMediaType() throws -> DiscMediaType? { nil }
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
