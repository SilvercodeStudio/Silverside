import Foundation

extension RipReport {
    /// A data track saved as an ISO image: its sectors' 2048 bytes of user data, one after
    /// another. An Enhanced CD's data track holds extras for a computer (videos, lyrics, a
    /// program); on most, it is an ISO 9660 file system, often with an HFS one for the Mac beside it.
    public struct DataTrack: Codable, Equatable, Sendable {
        public var number: Int
        /// The track's first sector on the disc. The ISO 9660 file system of a track in a later
        /// session (an Enhanced CD's) addresses the disc from its start, so a program that reads
        /// the image needs this offset: the image alone does not mount as an ISO.
        public var startLBA: Int?
        /// The file in the rip's folder, such as "Track 15.iso".
        public var file: String
        public var sectors: Int
        public var mode: DataSectorMode
        /// CRC-32 of the file, as eight hex digits.
        public var crc32: String
        /// Sectors, counted from the track's start, that could not be read. They are zeros in the file.
        public var unreadableSectors: [Int]?

        public init(
            number: Int, startLBA: Int? = nil, file: String, sectors: Int, mode: DataSectorMode, crc32: String,
            unreadableSectors: [Int]? = nil
        ) {
            self.number = number
            self.startLBA = startLBA
            self.file = file
            self.sectors = sectors
            self.mode = mode
            self.crc32 = crc32
            self.unreadableSectors = unreadableSectors
        }

        /// "Track 15.iso".
        public static func fileName(track: Int) -> String { String(format: "Track %02d.iso", track) }
    }
}

extension RipReport {
    /// "Data track 15 (Mode 1, 27,393 sectors, 53.5 MB): saved as Track 15.iso, CRC-32 1A2B3C4D", for the log.
    public static func dataTrackSummary(_ track: DataTrack) -> String {
        let megabytes = String(format: "%.1f MB", Double(track.sectors * 2048) / 1_048_576)
        var text =
            "Data track \(track.number) (\(track.mode), \(track.sectors.formatted()) sectors, \(megabytes)): saved as "
            + "\(track.file), CRC-32 \(track.crc32)"
        if let start = track.startLBA, start > 0 {
            text += "; it starts at sector \(start) of the disc, from which its file system counts"
        }
        if let unreadable = track.unreadableSectors {
            text += "; \(unreadable.count) sectors could not be read, and are zeros in the file"
        }
        return text
    }
}

/// Reads a data track into an ISO image.
public enum DataTrackReader {
    /// Sectors in one read: 26 × 2048 bytes fits the 64 KB transfer limit of many USB bridges.
    static let sectorsPerRead = 26

    /// Reads `track`, a data track, into `url`, a chunk at a time. A chunk that fails is read
    /// sector by sector, each up to `retries` more times; a sector that still fails is zeros
    /// in the file, and the result lists it. `progress` hears the fraction read. Throws if the
    /// track's first sector has no data mode that an ISO image holds, or once `stop` is stopped.
    public static func read(
        _ track: TOC.Track, in toc: TOC, drive: any CDDrive, to url: URL, retries: Int = 3, stop: StopToken? = nil,
        progress: ((Double) -> Void)? = nil
    ) throws -> RipReport.DataTrack {
        let range = toc.sectorRange(of: track)
        let mode = try drive.readDataMode(at: range.lowerBound)
        guard mode != .mode2Form2 else { throw DataTrackError.notData(track: track.number) }
        let partial = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).partial.iso")
        defer { try? FileManager.default.removeItem(at: partial) }
        guard FileManager.default.createFile(atPath: partial.path, contents: nil),
            let handle = try? FileHandle(forWritingTo: partial)
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path]) }
        defer { try? handle.close() }
        var crc: UInt32 = 0
        var unreadable = [Int]()
        for lba in stride(from: range.lowerBound, to: range.upperBound, by: sectorsPerRead) {
            try stop?.check()
            let count = min(sectorsPerRead, range.upperBound - lba)
            var bytes: [UInt8]
            do {
                bytes = try drive.readDataSectors(at: lba, count: count, mode: mode)
            } catch DriveError.readFailed {
                bytes = []
                for sector in lba..<(lba + count) {
                    var data: [UInt8]?
                    for _ in 0...retries where data == nil {
                        data = try? drive.readDataSectors(at: sector, count: 1, mode: mode)
                    }
                    if data == nil { unreadable.append(sector - range.lowerBound) }
                    bytes += data ?? [UInt8](repeating: 0, count: 2048)
                }
            }
            crc = CRC32.checksum(of: bytes, after: crc)
            try handle.write(contentsOf: bytes)
            progress?(Double(lba + count - range.lowerBound) / Double(range.count))
        }
        try handle.close()
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: partial, to: url)
        return RipReport.DataTrack(
            number: track.number, startLBA: range.lowerBound, file: url.lastPathComponent, sectors: range.count,
            mode: mode,
            crc32: String(format: "%08X", crc), unreadableSectors: unreadable.isEmpty ? nil : unreadable)
    }
}

public enum DataTrackError: Error, Equatable, CustomStringConvertible {
    case notData(track: Int)

    public var description: String {
        switch self {
        case .notData(let track): "Track \(track) holds no data that an ISO image can keep (Mode 2 Form 2)."
        }
    }
}
