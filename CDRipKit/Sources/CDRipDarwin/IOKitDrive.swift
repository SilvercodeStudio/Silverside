import CDRipKit
import Darwin
import IOKit.storage

/// A CD drive, read through its raw BSD device (/dev/rdiskN) with the IOCDMedia ioctls.
///
/// The ioctls work while cddafs has the disc mounted, so no DiskArbitration claim is needed to read.
public final class IOKitDrive: CDDrive {
    public let bsdName: String
    private let descriptor: Int32

    /// Opens a drive by its disc's BSD name, such as "disk14".
    public init(bsdName: String) throws(IOKitDriveError) {
        let path = "/dev/r" + bsdName
        descriptor = open(path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else { throw .openFailed(path: path, errno: errno) }
        self.bsdName = bsdName
    }

    deinit {
        close(descriptor)
    }

    public func readTOC() throws -> TOC {
        // 4 header bytes, then at most 3 session points and 99 tracks per session.
        var bytes = [UInt8](repeating: 0, count: 4096)
        var request = dk_cd_read_toc_t()
        request.format = UInt8(kCDTOCFormatTOC)
        try bytes.withUnsafeMutableBytes { buffer in
            request.buffer = buffer.baseAddress
            request.bufferLength = UInt16(buffer.count)
            try control(Ioctl.readTOC, &request)
        }
        return try TOC(fullTOC: Array(bytes.prefix(Int(request.bufferLength))))
    }

    public func readAudioSectors(at lba: Int, count: Int) throws -> [UInt8] {
        guard lba >= 0 else { throw DriveError.sectorOutOfRange(lba: lba) }
        var bytes = [UInt8](repeating: 0, count: count * CDDA.bytesPerSector)
        var request = dk_cd_read_t()
        request.offset = UInt64(lba * CDDA.bytesPerSector)
        request.sectorArea = UInt8(kCDSectorAreaUser.rawValue)
        request.sectorType = UInt8(kCDSectorTypeCDDA.rawValue)
        do {
            try bytes.withUnsafeMutableBytes { buffer in
                request.buffer = buffer.baseAddress
                request.bufferLength = UInt32(buffer.count)
                try control(Ioctl.read, &request)
            }
        } catch IOKitDriveError.ioctlFailed(errno: EIO) {
            throw DriveError.readFailed(lba: lba)
        }
        guard request.bufferLength == bytes.count else { throw DriveError.readFailed(lba: lba) }
        return bytes
    }

    private func control<Request>(_ code: UInt, _ request: inout Request) throws(IOKitDriveError) {
        let result = withUnsafeMutablePointer(to: &request) { ioctl(descriptor, code, $0) }
        guard result == 0 else { throw .ioctlFailed(errno: errno) }
    }
}

public enum IOKitDriveError: Error, Equatable {
    case openFailed(path: String, errno: Int32)
    case ioctlFailed(errno: Int32)
}

/// Request codes from IOCDMediaBSDClient.h. Swift does not import the _IOWR macro.
enum Ioctl {
    static let read = readWrite(96, dk_cd_read_t.self)
    static let readTOC = readWrite(100, dk_cd_read_toc_t.self)

    private static func readWrite<T>(_ number: UInt, _: T.Type) -> UInt {
        let inOut: UInt = 0xC000_0000
        let group = UInt(Character("d").asciiValue!)
        return inOut | (UInt(MemoryLayout<T>.size) & 0x1FFF) << 16 | group << 8 | number
    }
}
