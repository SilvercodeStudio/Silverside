/// Finds a drive's read offset: the offsets at which a track's AccurateRip v1
/// checksum agrees with a known checksum.
public enum AccurateRipOffsetFinder {
    /// Returns each offset in `-margin...margin` at which the checksum is in `checksums`.
    ///
    /// `samples` is the track as the drive returned it, with no offset correction,
    /// and with `margin` more samples before and after it. The track must not be
    /// the first or the last track, because AccurateRip skips samples there.
    public static func offsets(
        matching checksums: Set<UInt32>, in samples: [UInt32], trackLength: Int, margin: Int
    ) -> [Int] {
        precondition(trackLength > 0 && samples.count == trackLength + 2 * margin)
        let length = UInt32(trackLength)

        // The checksum and the sum of the window that starts at samples[0].
        var checksum: UInt32 = 0
        var sum: UInt32 = 0
        for index in 0..<trackLength {
            checksum &+= samples[index] &* UInt32(index + 1)
            sum &+= samples[index]
        }

        // Moving the window by one sample lowers each weight by one, so take away
        // the window's sum, and add the new last sample at the full weight.
        var matches = [Int]()
        for start in 0...(2 * margin) {
            if checksums.contains(checksum) {
                matches.append(start - margin)
            }
            guard start < 2 * margin else { break }
            let next = samples[start + trackLength]
            checksum = checksum &- sum &+ next &* length
            sum = sum &- samples[start] &+ next
        }
        return matches
    }
}
