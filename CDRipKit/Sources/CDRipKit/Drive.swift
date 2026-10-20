/// A CD drive that can read audio sectors. Hardware drives and `SimulatedDrive` conform to it.
public protocol CDDrive {
    func readTOC() throws -> TOC

    /// Reads raw audio sectors, 2352 bytes each. The data is not offset-corrected.
    func readAudioSectors(at lba: Int, count: Int) throws -> [UInt8]

    /// Reads the Q subchannel of `count` sectors. Frames can be damaged; check `isValid`.
    func readQSubchannel(at lba: Int, count: Int) throws -> [QSubchannel]
}

extension CDDrive {
    /// Reads the Q subchannel of one sector.
    public func readQSubchannel(at lba: Int) throws -> QSubchannel {
        try readQSubchannel(at: lba, count: 1)[0]
    }
}

public enum DriveError: Error, Equatable, CustomStringConvertible {
    case sectorOutOfRange(lba: Int)
    case readFailed(lba: Int)

    public var description: String {
        switch self {
        case .sectorOutOfRange(let lba): "Sector \(lba) is outside the disc"
        case .readFailed(let lba): "Cannot read sector \(lba)"
        }
    }
}
