/// Finds a drive's read offset: the offsets at which a track's samples agree
/// with a checksum from the AccurateRip database.
///
/// Both searches use v1-style checksums, which can be moved one sample at a
/// time. A track checksum in the database can be v1 or v2. The sector 450
/// checksum is v1-style in both cases, so it finds offsets for v2-only records too.
public enum AccurateRipOffsetFinder {
    /// Returns each offset in `-margin...margin` at which the track's v1 checksum is in `checksums`.
    ///
    /// `samples` is the track as the drive returned it, with no offset correction,
    /// and with `margin` more samples before and after it. The track must not be
    /// the first or the last track, because AccurateRip skips samples there.
    public static func offsets(
        matching checksums: Set<UInt32>, in samples: [UInt32], trackLength: Int, margin: Int
    ) -> [Int] {
        precondition(trackLength > 0 && samples.count == trackLength + 2 * margin)
        return slide(over: samples, windowStart: 0, windowLength: trackLength, steps: 2 * margin, matching: checksums)
            .map { $0 - margin }
    }

    /// Returns each offset in `-margin...margin` at which the checksum of the
    /// track's sector 450 is in `checksums`. The track must have at least 451 sectors.
    ///
    /// `samples` is as for `offsets(matching:in:trackLength:margin:)`.
    public static func frame450Offsets(
        matching checksums: Set<UInt32>, in samples: [UInt32], trackLength: Int, margin: Int
    ) -> [Int] {
        precondition(trackLength >= 451 * CDDA.samplesPerSector && samples.count == trackLength + 2 * margin)
        return slide(
            over: samples, windowStart: 450 * CDDA.samplesPerSector, windowLength: CDDA.samplesPerSector,
            steps: 2 * margin, matching: checksums
        ).map { $0 - margin }
    }

    /// Returns each step in `0...steps` at which the v1 checksum of the window
    /// that starts at `windowStart + step` is in `checksums`.
    private static func slide(
        over samples: [UInt32], windowStart: Int, windowLength: Int, steps: Int, matching checksums: Set<UInt32>
    ) -> [Int] {
        precondition(windowStart + windowLength + steps <= samples.count)
        let length = UInt32(windowLength)

        var checksum: UInt32 = 0
        var sum: UInt32 = 0
        for index in 0..<windowLength {
            checksum &+= samples[windowStart + index] &* UInt32(index + 1)
            sum &+= samples[windowStart + index]
        }

        // Moving the window by one sample lowers each weight by one, so take away
        // the window's sum, and add the new last sample at the full weight.
        var matches = [Int]()
        for step in 0...steps {
            if checksums.contains(checksum) {
                matches.append(step)
            }
            guard step < steps else { break }
            let first = samples[windowStart + step]
            let next = samples[windowStart + step + windowLength]
            checksum = checksum &- sum &+ next &* length
            sum = sum &- first &+ next
        }
        return matches
    }
}

extension AccurateRipOffsetFinder {
    /// Returns each offset in `-margin...margin` at which the checksum of one sector, read
    /// with `margin` more samples before and after it, is a sector 450 checksum in `known`,
    /// with that entry's confidence.
    static func sectorOffsets(
        matching known: [AccurateRipRecord.Track], in samples: [UInt32], margin: Int
    ) -> [(offset: Int, confidence: Int)] {
        precondition(samples.count == CDDA.samplesPerSector + 2 * margin)
        var confidences = [UInt32: Int]()
        for entry in known { confidences[entry.frame450Checksum, default: 0] += entry.confidence }
        let length = UInt32(CDDA.samplesPerSector)
        var checksum: UInt32 = 0
        var sum: UInt32 = 0
        for index in 0..<CDDA.samplesPerSector {
            checksum &+= samples[index] &* UInt32(index + 1)
            sum &+= samples[index]
        }
        var matches = [(offset: Int, confidence: Int)]()
        for step in 0...(2 * margin) {
            if let confidence = confidences[checksum] { matches.append((step - margin, confidence)) }
            guard step < 2 * margin else { break }
            let first = samples[step]
            let next = samples[step + CDDA.samplesPerSector]
            checksum = checksum &- sum &+ next &* length
            sum = sum &- first &+ next
        }
        return matches
    }
}

/// A drive's read offset, found from a disc that AccurateRip has, as EAC finds it with a key
/// disc: sector 450 of a few tracks, read with no offset correction, matches the database's
/// sector 450 checksums at the drive's offset. Each pressing in the database matches at an
/// offset of its own, so one disc can give several; the one that most tracks and the most
/// submissions share is the likeliest, and the rips of later discs confirm it
/// (`DriveProfile.confirmedOffset`). Only a drive that AccurateRip's list does not have needs it.
public struct DiscOffsetSearch: Equatable, Sendable {
    /// The offset to rip with.
    public var offset: Int
    /// The tracks whose sector 450 matches at `offset`, of the tracks searched.
    public var matchingTracks: Int
    public var searchedTracks: Int
    /// Other offsets that as many tracks match at: other pressings, the best supported first.
    public var otherOffsets: [Int] = []

    /// Samples searched on each side of 0: 5 sectors, wider than any offset in AccurateRip's list.
    static let margin = 5 * CDDA.samplesPerSector
    /// Tracks to read, at most: a few seconds of seeks.
    static let tracksToSearch = 6

    /// Searches the disc in `drive`, or nil if no offset matches on enough tracks: on two, or
    /// on the only one there is to search. An offset in `earlier` (offsets that earlier discs
    /// matched at, `DriveProfile.observations`) wins a tie.
    public static func find(
        drive: any CDDrive, toc: TOC, records: [AccurateRipRecord], earlier: Set<Int> = [], stop: StopToken? = nil
    ) throws -> DiscOffsetSearch? {
        var reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
        reader.unreadableRetries = 1
        reader.stop = stop
        var tracks = [Int: Int]()
        var confidences = [Int: Int]()
        var searched = 0
        for (index, track) in toc.audioTracks.enumerated() where searched < tracksToSearch {
            let sectors = toc.sectorRange(of: track)
            let known = records.entries(forTrackAt: index)
            guard sectors.count >= 451, !known.isEmpty else { continue }
            let start = (sectors.lowerBound + 450) * CDDA.samplesPerSector
            let read = try reader.read((start - margin)..<(start + CDDA.samplesPerSector + margin), withC2: false)
            guard read.unreadable.isEmpty else { continue }
            let matches = AccurateRipOffsetFinder.sectorOffsets(matching: known, in: read.samples, margin: margin)
            // A silent sector matches almost everywhere, and says nothing.
            guard matches.count <= TrackRipper.maximumFrame450Matches else { continue }
            searched += 1
            for offset in Set(matches.map(\.offset)) { tracks[offset, default: 0] += 1 }
            for match in matches { confidences[match.offset, default: 0] += match.confidence }
        }
        let ranked = tracks.keys.sorted {
            (tracks[$0]!, earlier.contains($0) ? 1 : 0, confidences[$0]!, -abs($0))
                > (tracks[$1]!, earlier.contains($1) ? 1 : 0, confidences[$1]!, -abs($1))
        }
        guard let best = ranked.first, tracks[best]! >= min(2, searched) else { return nil }
        return DiscOffsetSearch(
            offset: best, matchingTracks: tracks[best]!, searchedTracks: searched,
            otherOffsets: ranked.dropFirst().filter { tracks[$0] == tracks[best] })
    }
}
