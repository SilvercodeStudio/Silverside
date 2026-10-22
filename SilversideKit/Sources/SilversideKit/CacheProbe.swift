/// Finds how many sectors a drive caches, from read times. A sector that the cache
/// holds comes back in about a millisecond; one read from the disc takes far longer,
/// because the drive must seek and wait for the disc to turn.
///
/// The probe reads a sector, then `n` sectors far away, then the first sector again.
/// If that read is fast, the cache still held the sector, so it holds more than `n`.
/// It doubles `n` until the sector is gone, then bisects.
public struct CacheProbe {
    /// Reads sectors and returns the time the read took. Tests replace it.
    public var timedRead: (_ lba: Int, _ count: Int) throws -> Duration

    /// A read faster than this came from the cache.
    public var cachedReadLimit = Duration.milliseconds(10)

    /// The bisection stops when the bounds are this close.
    public var precision = 32

    /// The largest cache to look for, in sectors (about 47 MB).
    public var maximumSectors = 20_000

    public init(drive: any CDDrive) {
        timedRead = { lba, count in
            let clock = ContinuousClock()
            return try clock.measure { _ = try drive.readAudioSectors(at: lba, count: count) }
        }
    }

    public init(timedRead: @escaping (_ lba: Int, _ count: Int) throws -> Duration) {
        self.timedRead = timedRead
    }

    /// The smallest number of other sectors, read after a sector, that remove it from
    /// the cache: an upper bound of the cache's size, within `precision`. Nil if no
    /// number up to `maximumSectors` does, or if the disc is too short for the test.
    /// The sectors must read without errors: use a clean part of the disc.
    public func cacheSectors(toc: TOC) throws -> Int? {
        guard let first = toc.audioTracks.first, let last = toc.audioTracks.last else { return nil }
        // The test sector is near the start, and the other reads are as far from it as the disc allows.
        let target = first.startLBA + 300
        let far = toc.sectorRange(of: last).upperBound - 300
        guard far - maximumSectors >= target + 1000 else { return nil }

        func evicts(_ count: Int) throws -> Bool {
            _ = try timedRead(target, 1)
            let start = far - count
            for lba in stride(from: start, to: start + count, by: 26) {
                _ = try timedRead(lba, min(26, start + count - lba))
            }
            return try timedRead(target, 1) >= cachedReadLimit
        }

        var low = 0
        var high = 64
        while try !evicts(high) {
            low = high
            guard high < maximumSectors else { return nil }
            high = min(2 * high, maximumSectors)
        }
        while high - low > precision {
            let middle = (low + high) / 2
            if try evicts(middle) { high = middle } else { low = middle }
        }
        return high
    }
}
