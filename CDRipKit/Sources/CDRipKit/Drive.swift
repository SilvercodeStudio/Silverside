/// A CD drive that can read audio sectors. Hardware drives and `SimulatedDrive` conform to it.
public protocol CDDrive {
    func readTOC() throws -> TOC

    /// Reads raw audio sectors, 2352 bytes each. The data is not offset-corrected.
    func readAudioSectors(at lba: Int, count: Int) throws -> [UInt8]
}

public enum DriveError: Error, Equatable {
    case sectorOutOfRange(lba: Int)
    case readFailed(lba: Int)
}
