import Darwin
import IOKit
import IOKit.storage
import SilversideKit

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
        do {
            try bytes.withUnsafeMutableBytes { buffer in
                request.buffer = buffer.baseAddress
                request.bufferLength = UInt16(buffer.count)
                try control(Ioctl.readTOC, &request)
            }
        } catch IOKitDriveError.ioctlFailed(errno: EIO) {
            throw DriveError.tocUnreadable
        }
        return try TOC(fullTOC: Array(bytes.prefix(Int(request.bufferLength))))
    }

    public func readAudioSectors(at lba: Int, count: Int) throws -> [UInt8] {
        try readAudioSectors(at: lba, count: count, c2: false, q: false).audio
    }

    /// Reads the CD-Text with the TOC ioctl in its CD-Text format. A disc with no CD-Text
    /// gives an error or no packs: either way, nil.
    public func readCDText() throws -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 65_535)
        var request = dk_cd_read_toc_t()
        request.format = UInt8(kCDTOCFormatTEXT)
        do {
            try bytes.withUnsafeMutableBytes { buffer in
                request.buffer = buffer.baseAddress
                request.bufferLength = UInt16(buffer.count)
                try control(Ioctl.readTOC, &request)
            }
        } catch {
            return nil
        }
        let length = Int(request.bufferLength)
        return length > 4 ? Array(bytes.prefix(length)) : nil
    }

    /// What the disc is. The I/O Registry's IOCDMedia "Type" says CD-R or CD-RW for a disc
    /// that is still open; a finished CD-R is "CD-ROM" there (a Memorex CD-R in the MATSHITA,
    /// 2026-10-23). So a "CD-ROM" is then asked for its ATIP, which only a disc written in a
    /// drive has: the TOC ioctl in its ATIP format, as XLD does it. A pressed disc gives an
    /// error or no lead-in start time; byte 6's bit 6 tells a CD-RW from a CD-R.
    public func readMediaType() throws -> DiscMediaType? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsdName))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let type =
            IORegistryEntryCreateCFProperty(service, kIOCDMediaTypeKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        switch type {
        case kIOCDMediaTypeR: return .recordable
        case kIOCDMediaTypeRW: return .rewritable
        case kIOCDMediaTypeROM: return readATIP() ?? .pressed
        default: return nil
        }
    }

    /// The media type from the disc's ATIP, or nil when the disc has none (pressed) or the drive refuses.
    private func readATIP() -> DiscMediaType? {
        var bytes = [UInt8](repeating: 0, count: 32)
        var request = dk_cd_read_toc_t()
        request.format = UInt8(kCDTOCFormatATIP)
        do {
            try bytes.withUnsafeMutableBytes { buffer in
                request.buffer = buffer.baseAddress
                request.bufferLength = UInt16(buffer.count)
                try control(Ioctl.readTOC, &request)
            }
        } catch {
            return nil
        }
        // Bytes 8 to 10 are the start time of the lead-in, which every ATIP has.
        guard request.bufferLength >= 11, bytes[8] != 0 || bytes[9] != 0 || bytes[10] != 0 else { return nil }
        return bytes[6] & 0x40 != 0 ? .rewritable : .recordable
    }

    public func readAudioSectorsWithC2(at lba: Int, count: Int) throws -> (audio: [UInt8], errorFlags: [UInt8]) {
        let read = try readAudioSectors(at: lba, count: count, c2: true, q: false)
        return (read.audio, read.errorFlags)
    }

    /// Reads the Q subchannel together with the user area, because the
    /// drives tested so far reject a read of Q alone.
    public func readQSubchannel(at lba: Int, count: Int) throws -> [QSubchannel] {
        try readAudioSectors(at: lba, count: count, c2: false, q: true).q
    }

    /// Reads the user area, and the C2 flags and Q subchannel as asked, in one command. Each
    /// sector comes back as its user area, then its flags, then 16 bytes of Q (12 used).
    public func readAudioSectors(at lba: Int, count: Int, c2: Bool, q: Bool) throws -> SectorRead {
        guard lba >= 0 else { throw DriveError.sectorOutOfRange(lba: lba) }
        let flagBytes = c2 ? CDDA.errorFlagBytesPerSector : 0
        let qBytes = q ? 16 : 0
        let sectorSize = CDDA.bytesPerSector + flagBytes + qBytes
        var bytes = [UInt8](repeating: 0, count: count * sectorSize)
        var request = dk_cd_read_t()
        request.offset = UInt64(lba * sectorSize)
        request.sectorArea = UInt8(
            kCDSectorAreaUser.rawValue | (c2 ? kCDSectorAreaErrorFlags.rawValue : 0)
                | (q ? kCDSectorAreaSubChannelQ.rawValue : 0))
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
        guard c2 || q else { return SectorRead(audio: bytes) }
        var read = SectorRead(audio: [])
        read.audio.reserveCapacity(count * CDDA.bytesPerSector)
        read.errorFlags.reserveCapacity(count * flagBytes)
        for sector in 0..<count {
            let start = sector * sectorSize
            read.audio += bytes[start..<(start + CDDA.bytesPerSector)]
            read.errorFlags += bytes[(start + CDDA.bytesPerSector)..<(start + CDDA.bytesPerSector + flagBytes)]
            if q {
                let qStart = start + CDDA.bytesPerSector + flagBytes
                read.q.append(QSubchannel(bytes: Array(bytes[qStart..<(qStart + QSubchannel.byteCount)])))
            }
        }
        return read
    }

    private func control<Request>(_ code: UInt, _ request: inout Request) throws(IOKitDriveError) {
        let result = withUnsafeMutablePointer(to: &request) { ioctl(descriptor, code, $0) }
        guard result == 0 else { throw .ioctlFailed(errno: errno) }
    }
}

public enum IOKitDriveError: Error, Equatable, CustomStringConvertible {
    case openFailed(path: String, errno: Int32)
    case ioctlFailed(errno: Int32)

    public var description: String {
        switch self {
        case .openFailed(let path, let code): "Cannot open \(path): \(String(cString: strerror(code)))"
        case .ioctlFailed(let code): "The drive request failed: \(String(cString: strerror(code)))"
        }
    }
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
