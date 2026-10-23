/// The audio of one track, read from the disc a piece at a time, for playback: a second of
/// audio for each read, so the drive reads in short bursts and a listener can seek. The
/// reads go through `AudioReader`, so a sector that cannot be read is silence, not a stop.
public struct DiscAudioStream {
    public let reader: AudioReader
    public let track: TOC.Track
    /// The track's sectors on the disc.
    public let sectors: Range<Int>
    /// Sectors in each piece: 75 is one second.
    public var sectorsPerPiece = CDDA.sectorsPerSecond
    /// The next sector to read, counted from the track's start.
    public private(set) var position: Int

    public init(reader: AudioReader, track: TOC.Track, startingAtSector sector: Int = 0) {
        self.reader = reader
        self.track = track
        sectors = reader.toc.sectorRange(of: track)
        position = min(max(sector, 0), sectors.count)
    }

    /// The track's length in sectors.
    public var count: Int { sectors.count }

    public var isAtEnd: Bool { position >= count }

    /// Continues from another sector of the track.
    public mutating func seek(toSector sector: Int) {
        position = min(max(sector, 0), count)
    }

    /// The next piece of the track, or nil at its end.
    public mutating func next() throws -> [UInt32]? {
        guard !isAtEnd else { return nil }
        let pieceSectors = min(sectorsPerPiece, count - position)
        let start = (sectors.lowerBound + position) * CDDA.samplesPerSector
        let samples = try reader.readSamples(start..<(start + pieceSectors * CDDA.samplesPerSector))
        position += pieceSectors
        return samples
    }
}
