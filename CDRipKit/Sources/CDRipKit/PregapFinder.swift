/// Finds each track's pregap (index 00) from the Q subchannel.
public enum PregapFinder {
    /// Returns the pregap length in sectors of each audio track, by track number.
    ///
    /// Track 1's pregap is the part of the disc before its start, which can hold a
    /// hidden track. Tracks after a data track or a session gap are left out.
    public static func pregaps(of toc: TOC, drive: any CDDrive) throws -> [Int: Int] {
        var pregaps = [Int: Int]()
        for track in toc.tracks {
            pregaps[track.number] = try pregap(of: track, in: toc, drive: drive)
        }
        return pregaps
    }

    /// Returns one track's pregap length in sectors, or nil for a data track or a
    /// track after a data track or a session gap. Throws `PregapError` if the Q
    /// subchannel near the pregap's start cannot be read.
    public static func pregap(of track: TOC.Track, in toc: TOC, drive: any CDDrive) throws -> Int? {
        guard track.kind == .audio, let index = toc.tracks.firstIndex(of: track) else { return nil }
        guard index > 0 else { return track.startLBA }
        let previous = toc.tracks[index - 1]
        guard previous.kind == .audio, previous.session == track.session else { return nil }
        let start = try firstSector(ofTrack: track.number, in: (previous.startLBA + 1)..<track.startLBA, drive: drive)
        return track.startLBA - start
    }

    /// The first sector in `range` whose Q subchannel names `track`, or the end of
    /// the range if none does. In the range, Q names the previous track until the
    /// pregap starts, so a binary search finds the change.
    private static func firstSector(ofTrack track: Int, in range: Range<Int>, drive: any CDDrive) throws -> Int {
        var low = range.lowerBound
        var high = range.upperBound
        while low < high {
            let (sector, position) = try readPosition(near: low + (high - low) / 2, in: low..<high, drive: drive)
            if position.track == track {
                high = sector
            } else {
                low = sector + 1
            }
        }
        return low
    }

    /// Reads a position frame at `lba`. If that frame is damaged, or is an MCN or
    /// ISRC frame, reads the nearest sector in `range` that has a position frame.
    private static func readPosition(
        near lba: Int, in range: Range<Int>, drive: any CDDrive
    ) throws -> (sector: Int, position: QSubchannel.Position) {
        for distance in 0..<16 {
            for sector in Set([lba - distance, lba + distance]).sorted() where range.contains(sector) {
                // Read a damaged frame again once. A valid MCN or ISRC frame does not change.
                for _ in 0..<2 {
                    let frame = try drive.readQSubchannel(at: sector)
                    if let position = frame.position { return (sector, position) }
                    if frame.isValid { break }
                }
            }
        }
        throw PregapError.unreadableSubchannel(lba: lba)
    }
}

public enum PregapError: Error, Equatable, CustomStringConvertible {
    case unreadableSubchannel(lba: Int)

    public var description: String {
        switch self {
        case .unreadableSubchannel(let lba): "Cannot read the Q subchannel near sector \(lba)"
        }
    }
}
