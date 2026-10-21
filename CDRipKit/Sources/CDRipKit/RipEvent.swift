/// What a rip is doing, for a progress line now and a live graph in the app later.
public enum RipEvent: Equatable, Sendable {
    /// A read of a whole track. Pass 1 is the first read; later passes are reads again, to compare.
    /// The counts are drive sectors, so far in this pass: with the read offset, a read covers
    /// one sector more than the track, and one sector's data can lie in two drive sectors.
    case reading(track: Int, pass: Int, sectorsRead: Int, sectors: Int, c2Sectors: Int, unreadableSectors: Int)
    /// A round of re-reads of the suspect sectors: how many sectors, and how many versions are known.
    case rereading(track: Int, round: Int, maximumRounds: Int, suspectSectors: Int, versions: Int)
}

/// How far a read has come, as `AudioReader` reports it after each chunk.
public struct ReadProgress: Equatable, Sendable {
    public var sectorsRead: Int
    public var sectors: Int
    /// Sectors with a C2 error so far.
    public var flaggedSectors: Int
    /// Sectors that could not be read so far.
    public var unreadableSectors: Int
}
