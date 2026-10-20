/// Reads MCN and ISRC codes from the Q subchannel. About 1 in 100 frames holds a
/// code. The drive commands for these codes can return the previous track's
/// ISRC, so the frames themselves are more reliable.
public enum SubchannelCodes {
    /// Give up after this many sectors without two frames that agree.
    static let maximumSectors = 600
    static let sectorsPerRead = 26

    /// A track's ISRC, from frames in the middle of the track. Nil if the track has none.
    public static func isrc(of track: TOC.Track, in toc: TOC, drive: any CDDrive) throws -> String? {
        let sectors = toc.sectorRange(of: track)
        return try code(in: sectors, from: sectors.lowerBound + sectors.count / 2, drive: drive, \.isrc)
    }

    /// The disc's MCN (barcode), from frames in the first audio track. Nil if the
    /// disc has none. Some discs store thirteen zeros, which also means none.
    public static func mcn(in toc: TOC, drive: any CDDrive) throws -> String? {
        guard let track = toc.audioTracks.first else { return nil }
        let sectors = toc.sectorRange(of: track)
        let mcn = try code(in: sectors, from: sectors.lowerBound + sectors.count / 2, drive: drive, \.mcn)
        return mcn?.allSatisfy { $0 == "0" } == true ? nil : mcn
    }

    /// The first code that two frames agree on, reading from `start` to the end of
    /// `range` and then from its beginning. If only one frame has a code, that code.
    private static func code(
        in range: Range<Int>, from start: Int, drive: any CDDrive, _ value: (QSubchannel) -> String?
    ) throws -> String? {
        var counts = [String: Int]()
        var first: String?
        var lba = start
        var sectorsRead = 0
        while sectorsRead < min(maximumSectors, range.count) {
            if lba >= range.upperBound { lba = range.lowerBound }
            let count = min(sectorsPerRead, range.upperBound - lba)
            for code in try drive.readQSubchannel(at: lba, count: count).compactMap(value) {
                counts[code, default: 0] += 1
                if counts[code] == 2 { return code }
                first = first ?? code
            }
            lba += count
            sectorsRead += count
        }
        return first
    }
}
