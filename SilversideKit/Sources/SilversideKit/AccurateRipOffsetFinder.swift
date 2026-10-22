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
