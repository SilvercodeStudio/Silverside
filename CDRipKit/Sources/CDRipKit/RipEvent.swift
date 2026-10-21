/// What a rip is doing, for a progress line and for a live graph of the track in the app.
/// Sectors are counted from the track's start, as in `SecureTrackRip`.
public enum RipEvent: Equatable, Sendable {
    /// A read of a whole track goes on. Pass 1 is the first read; later passes are reads
    /// again, to compare. The progress counts drive sectors, so far in this pass: with the
    /// read offset, a read covers one sector more than the track, and one drive sector's
    /// data can lie in two sectors of the track.
    case reading(track: Int, pass: Int, progress: ReadProgress)
    /// A round of re-reads of the suspect sectors: which sectors, and how many versions are known.
    case rereading(track: Int, round: Int, maximumRounds: Int, suspectSectors: [Int], versions: Int)
}

/// How far a read has come, as `AudioReader` reports it after each chunk.
public struct ReadProgress: Equatable, Sendable {
    public var sectorsRead: Int
    public var sectors: Int
    /// Sectors with a C2 error so far.
    public var flaggedSectors: Int
    /// Sectors that could not be read so far.
    public var unreadableSectors: Int
    /// The sectors that this chunk read. From `AudioReader`, drive sectors (LBAs). In a
    /// `RipEvent`, sectors counted from the track's start, which can begin before 0 and end
    /// past the track, because a read covers a margin on each side and the drive's offset.
    public var chunk: Range<Int> = 0..<0
    /// The sectors in this chunk with a C2 error.
    public var flaggedInChunk: [Int] = []
    /// The sectors in this chunk that could not be read.
    public var unreadableInChunk: [Int] = []

    /// The same progress with its sectors counted from the start of a track whose first
    /// sample is at `start`, as a drive with `readOffset` lays them out. A drive sector
    /// whose data lies in two sectors of the track counts for both.
    func inTrack(startingAt start: Int, readOffset: Int) -> ReadProgress {
        func sector(at position: Int) -> Int { (position - start).floorDivided(by: CDDA.samplesPerSector) }
        func sectors(ofDriveSector lba: Int) -> [Int] {
            let first = sector(at: lba * CDDA.samplesPerSector - readOffset)
            let last = sector(at: (lba + 1) * CDDA.samplesPerSector - 1 - readOffset)
            return first == last ? [first] : [first, last]
        }
        var result = self
        result.chunk =
            chunk.isEmpty
            ? 0..<0
            : sector(
                at: chunk.lowerBound * CDDA.samplesPerSector - readOffset)..<(sector(
                    at: chunk.upperBound * CDDA.samplesPerSector - 1 - readOffset) + 1)
        result.flaggedInChunk = Set(flaggedInChunk.flatMap(sectors(ofDriveSector:))).sorted()
        result.unreadableInChunk = Set(unreadableInChunk.flatMap(sectors(ofDriveSector:))).sorted()
        return result
    }
}
