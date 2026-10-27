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
        let start = try firstSector(
            in: (previous.startLBA + 1)..<track.startLBA, tracks: (track.number - 1)...track.number, drive: drive
        ) { $0.track == track.number }
        return track.startLBA - start
    }

    /// The index points after 01 of an audio track: where its index 02, 03, and so on start,
    /// in sectors after its index 01. Most discs have none; some classical discs mark
    /// movements or passages with them. `positions` are the Q frames' positions from the
    /// track's rip (`TrackRip.qPositions`); where they leave a change unknown by more than a
    /// sector (a damaged frame there, or an MCN or ISRC frame), the drive's Q subchannel is
    /// read again. If it cannot be, the index starts at the first frame that names it.
    public static func indexes(
        of track: TOC.Track, in toc: TOC, positions: [QSubchannel.Position], drive: any CDDrive
    ) -> [RipReport.Index] {
        let range = toc.sectorRange(of: track)
        let named = positions.filter { $0.track == track.number && $0.index >= 1 && range.contains($0.lba) }
        // A frame whose CRC passes can still be wrong, so an index that one frame names is not
        // taken, and its frame does not move the other indexes' changes either.
        let counts = Dictionary(grouping: named, by: \.index).mapValues(\.count)
        let own = named.filter { $0.index == 1 || counts[$0.index]! >= 2 }
        var indexes = [RipReport.Index]()
        for number in counts.keys.sorted() where number >= 2 && counts[number]! >= 2 {
            let before = own.filter { $0.index < number }.map(\.lba).max() ?? range.lowerBound
            guard let at = own.filter({ $0.index >= number }).map(\.lba).min(), before < at else { continue }
            let start =
                at - before == 1
                ? at
                : (try? firstSector(in: (before + 1)..<at, tracks: track.number...track.number, drive: drive) {
                    $0.index >= number
                }) ?? at
            indexes.append(RipReport.Index(number: number, sectors: start - range.lowerBound))
        }
        return indexes
    }

    /// The first sector in `range` whose Q frame's position is `isAfter` a change, or the end
    /// of the range if none is. Before the change, frames name the earlier track or index,
    /// so a binary search finds it.
    private static func firstSector(
        in range: Range<Int>, tracks: ClosedRange<Int>, drive: any CDDrive,
        where isAfter: (QSubchannel.Position) -> Bool
    ) throws -> Int {
        var low = range.lowerBound
        var high = range.upperBound
        while low < high {
            // Sectors with only MCN or ISRC frames left between two known positions
            // belong to the earlier part: no position frame says the change is there.
            guard
                let (sector, position) = try readPosition(
                    near: low + (high - low) / 2, in: low..<high, tracks: tracks, drive: drive)
            else { return high }
            if isAfter(position) {
                high = sector
            } else {
                low = sector + 1
            }
        }
        return low
    }

    /// Reads a position frame at `lba`. If that frame is damaged, or is an MCN or
    /// ISRC frame, reads the nearest sector in `range` that has a position frame.
    /// Returns nil if the sectors near `lba` in `range` have only valid MCN or ISRC frames.
    private static func readPosition(
        near lba: Int, in range: Range<Int>, tracks: ClosedRange<Int>, drive: any CDDrive
    ) throws -> (sector: Int, position: QSubchannel.Position)? {
        var damaged = [(sector: Int, frame: QSubchannel)]()
        for distance in 0..<16 {
            for sector in Set([lba - distance, lba + distance]).sorted() where range.contains(sector) {
                // Read a damaged frame again once. A valid MCN or ISRC frame does not change.
                for attempt in 0..<2 {
                    let frame = try drive.readQSubchannel(at: sector)
                    if let position = frame.position { return (sector, position) }
                    if frame.isValid { break }
                    if attempt == 1 { damaged.append((sector, frame)) }
                }
            }
        }
        guard !damaged.isEmpty else { return nil }
        // Some discs have a bad CRC in the frame just before each track change, with
        // correct contents. Use such a frame only if its absolute time is the sector
        // read and it names one of the two tracks.
        for (sector, frame) in damaged {
            if let position = frame.unverifiedPosition, position.lba == sector, tracks.contains(position.track) {
                return (sector, position)
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
