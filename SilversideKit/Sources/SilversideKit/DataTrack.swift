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
        /// The sectors at the track's end, after its file systems, that were not read: zeros in
        /// the file. A data track's post-gap is empty, and can be unreadable; one drive (ASUS
        /// BW-16D1HT) stops answering there. Nil when the whole track was read.
        public var skippedSectors: Int?

        public init(
            number: Int, startLBA: Int? = nil, file: String, sectors: Int, mode: DataSectorMode, crc32: String,
            unreadableSectors: [Int]? = nil, skippedSectors: Int? = nil
        ) {
            self.number = number
            self.startLBA = startLBA
            self.file = file
            self.sectors = sectors
            self.mode = mode
            self.crc32 = crc32
            self.unreadableSectors = unreadableSectors
            self.skippedSectors = skippedSectors
        }

        /// "Track 15.iso".
        public static func fileName(track: Int) -> String { String(format: "Track %02d.iso", track) }
    }
}

extension RipReport {
    /// A data track that a rip was to save, and could not.
    public struct DataTrackFailure: Codable, Equatable, Sendable {
        public var number: Int
        /// Why, for people: the error, or that the rip was stopped.
        public var reason: String

        public init(number: Int, reason: String) {
            self.number = number
            self.reason = reason
        }
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
        if let skipped = track.skippedSectors {
            text += "; the last \(skipped.formatted()) sectors, after its file systems, were not read and are zeros"
        }
        return text
    }
}

/// What to do with a disc's data tracks (an Enhanced CD's extras for a computer).
public enum DataTrackChoice: String, Codable, CaseIterable, Sendable {
    /// The app asks when a rip of such a disc starts; the command line asks at a terminal, and saves otherwise.
    case ask
    /// Save each data track as an ISO image, and its files beside it in the album folder.
    case save
    /// Rip the audio only.
    case skip
}

/// Reads a data track into an ISO image.
public enum DataTrackReader {
    /// Sectors in one read: 26 × 2048 bytes fits the 64 KB transfer limit of many USB bridges.
    static let sectorsPerRead = 26

    /// Reads `track`, a data track, into `url`, a chunk at a time. A chunk that fails is read
    /// sector by sector, each up to `retries` more times; a sector that still fails is zeros
    /// in the file, and the result lists it. `progress` hears the fraction read. Throws if the
    /// track's first sector has no data mode that an ISO image holds, once `stop` is stopped,
    /// or after `giveUpAfter` sectors in a row fail: a drive that cannot read a data session
    /// would otherwise retry every sector of it, which can take hours. The sectors after the
    /// track's file systems (`fileSystemEnd`), its empty post-gap, are not read: they are zeros
    /// in the file, as a drive that reads them gives.
    public static func read(
        _ track: TOC.Track, in toc: TOC, drive: any CDDrive, to url: URL, retries: Int = 3,
        giveUpAfter: Int = 200, stop: StopToken? = nil, progress: ((Double) -> Void)? = nil
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
        var failedInARow = 0
        // Where the reads end: the track's end, until the first chunk shows its file systems.
        var readEnd = range.upperBound
        for lba in stride(from: range.lowerBound, to: range.upperBound, by: sectorsPerRead) where lba < readEnd {
            try stop?.check()
            let count = min(sectorsPerRead, readEnd - lba)
            var bytes: [UInt8]
            do {
                bytes = try drive.readDataSectors(at: lba, count: count, mode: mode)
                failedInARow = 0
            } catch DriveError.readFailed {
                bytes = []
                for sector in lba..<(lba + count) {
                    try stop?.check()
                    var data: [UInt8]?
                    for _ in 0...retries where data == nil {
                        data = try? drive.readDataSectors(at: sector, count: 1, mode: mode)
                    }
                    if data == nil {
                        unreadable.append(sector - range.lowerBound)
                        failedInARow += 1
                        if failedInARow >= giveUpAfter {
                            throw DataTrackError.unreadable(track: track.number, sectors: failedInARow)
                        }
                    } else {
                        failedInARow = 0
                    }
                    bytes += data ?? [UInt8](repeating: 0, count: 2048)
                }
            }
            if lba == range.lowerBound,
                let end = fileSystemEnd(of: bytes, startLBA: range.lowerBound, sectors: range.count)
            {
                readEnd = max(range.lowerBound + end, lba + count)
            }
            crc = CRC32.checksum(of: bytes, after: crc)
            try handle.write(contentsOf: bytes)
            progress?(Double(lba + count - range.lowerBound) / Double(range.count))
        }
        let skipped = range.upperBound - readEnd
        if skipped > 0 {
            let zeros = [UInt8](repeating: 0, count: skipped * 2048)
            crc = CRC32.checksum(of: zeros, after: crc)
            try handle.write(contentsOf: zeros)
            progress?(1)
        }
        try handle.close()
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: partial, to: url)
        return RipReport.DataTrack(
            number: track.number, startLBA: range.lowerBound, file: url.lastPathComponent, sectors: range.count,
            mode: mode,
            crc32: String(format: "%08X", crc), unreadableSectors: unreadable.isEmpty ? nil : unreadable,
            skippedSectors: skipped > 0 ? skipped : nil)
    }

    /// The sectors that a data track's file systems use, from its first sectors' bytes: the
    /// ISO 9660 volume's size, and the end of each partition of an Apple partition map (a
    /// Mac's HFS beside the ISO). A session-2 ISO volume counts from the disc's start, as
    /// `startLBA` does. Nil, so that the whole track is read, when neither is there, when
    /// either says more than the track holds, or when the partition map's end is not certain.
    static func fileSystemEnd(of bytes: [UInt8], startLBA: Int, sectors: Int) -> Int? {
        func uint32(_ offset: Int, bigEndian: Bool) -> Int {
            let word = bytes[offset..<(offset + 4)]
            return (bigEndian ? word : word.reversed()[...]).reduce(0) { $0 << 8 | Int($1) }
        }
        var ends = [Int]()
        let pvd = 16 * 2048
        if bytes.count >= pvd + 2048, bytes[pvd] == 1, Array(bytes[(pvd + 1)..<(pvd + 6)]) == Array("CD001".utf8) {
            let size = uint32(pvd + 80, bigEndian: false)
            ends.append(size > startLBA ? size - startLBA : size)
        }
        switch appleMapEnd(of: bytes) {
        case .none: break
        case .end(let end): ends.append(end)
        case .uncertain: return nil
        }
        guard let end = ends.max(), end > 0, end <= sectors else { return nil }
        return end
    }

    enum AppleMapEnd: Equatable {
        case none
        /// The sector after the last partition.
        case end(Int)
        /// A map whose partitions cannot all be read.
        case uncertain
    }

    /// The end of an Apple partition map's partitions, in 2048-byte sectors. The map's blocks
    /// are the size that the driver descriptor ("ER" in block 0) gives, 512 or 2048 bytes on
    /// a CD, and 512 without a descriptor, as Apple's partition scheme reads them; the entries
    /// ("PM") fill blocks 1 on, and count their partitions in those blocks.
    static func appleMapEnd(of bytes: [UInt8]) -> AppleMapEnd {
        func uint32(_ offset: Int) -> Int { bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) } }
        func isEntry(_ offset: Int) -> Bool {
            offset + 16 <= bytes.count && bytes[offset] == 0x50 && bytes[offset + 1] == 0x4D
        }
        let hasDescriptor = bytes.count >= 4 && bytes[0] == 0x45 && bytes[1] == 0x52
        let size = hasDescriptor ? Int(bytes[2]) << 8 | Int(bytes[3]) : 512
        guard isEntry(size) || hasDescriptor else { return .none }
        // A descriptor whose map is not where its block size puts it: the blocks are not known.
        guard [512, 1024, 2048, 4096].contains(size), isEntry(size) else { return .uncertain }
        let entries = uint32(size + 4)
        // Every entry must be in the bytes read, or a partition past them could be missed.
        guard entries >= 1, (entries + 1) * size <= bytes.count else { return .uncertain }
        var end = 0
        for entry in 1...entries {
            guard isEntry(size * entry) else { return .uncertain }
            let blocks = uint32(size * entry + 8) + uint32(size * entry + 12)
            end = max(end, (blocks * size + 2047) / 2048)
        }
        return .end(end)
    }
}

public enum DataTrackError: Error, Equatable, CustomStringConvertible {
    case notData(track: Int)
    /// The disc in the drive is not the rip's.
    case otherDisc
    /// So many sectors in a row failed that the drive most likely cannot read the track.
    case unreadable(track: Int, sectors: Int)

    public var description: String {
        switch self {
        case .notData(let track): "Track \(track) holds no data that an ISO image can keep (Mode 2 Form 2)."
        case .otherDisc: "The disc in the drive is not the one that was ripped."
        case .unreadable(let track, let sectors):
            "The drive could not read \(sectors) sectors in a row of track \(track), so it stopped. "
                + "Another drive may read it."
        }
    }
}
