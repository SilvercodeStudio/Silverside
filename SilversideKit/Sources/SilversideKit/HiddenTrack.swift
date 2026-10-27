/// Audio before track 1's index 01 (hidden track one audio, "HTOA"). Some discs hide a
/// song there, which a player only reaches by rewinding from track 1. Most discs have a
/// short gap of silence there instead (about 32 sectors on several test discs).
///
/// AccurateRip and CTDB do not cover this part of the disc, so the only check is that
/// reads agree.
public struct HiddenTrackRip: Sendable {
    public var samples: [UInt32]
    /// The largest sample value, left or right, as a 16-bit magnitude.
    public var peak: Int
    /// True if two reads gave the same data.
    public var readsAgree: Bool
    public var reads: Int
    /// Samples from sectors that no read could read. They are silence.
    public var unreadableSamples: [Int] = []
    public var cacheFlushIncomplete = false

    /// True if sectors could not be read and the recovered samples are silence. Some drives
    /// cannot read before track 1. Non-silent audio is kept even when offset correction
    /// recovers only a fragment shorter than a sector.
    public var isUnreadable: Bool {
        !unreadableSamples.isEmpty && peak < Self.silencePeak
    }

    /// True if less than a sector of the samples could be read.
    static func readsNothing(_ unreadable: [Int], of count: Int) -> Bool {
        !unreadable.isEmpty && unreadable.count > count - CDDA.samplesPerSector
    }

    /// Below this peak, the gap is silence (or dither), not a hidden track.
    public static let silencePeak = 32

    /// Reads the part of the disc before track 1, and returns it if it is audio, not
    /// silence, or if sectors could not be read (`isUnreadable` tells which). Nil if track 1
    /// starts at LBA 0, or the gap is silent, or track 1 is a data track (a mixed-mode disc),
    /// which no drive reads as audio.
    public static func rip(reader: AudioReader, cacheFlushSectors: Int = 4000, maximumReads: Int = 4) throws
        -> HiddenTrackRip?
    {
        guard let first = reader.toc.audioTracks.first, first == reader.toc.tracks[0], first.startLBA > 0 else {
            return nil
        }
        let positions = 0..<(first.startLBA * CDDA.samplesPerSector)
        let firstRead = try reader.read(positions, withC2: false)
        func peak(_ read: AudioReader.Read) -> Int { read.samples.reduce(0) { max($0, magnitude(of: $1)) } }
        // A failed read that was replaced by zero is not evidence of a silent gap.
        if firstRead.unreadable.isEmpty && peak(firstRead) < silencePeak { return nil }
        var reads = [firstRead]
        var incomplete = false
        while reads.count < max(1, maximumReads) {
            // A drive that cannot read here reads nothing on each pass, and each pass retries
            // every sector: two such passes are enough. One can be a run of bad reads.
            if reads.count >= 2, reads.suffix(2).allSatisfy({ readsNothing($0.unreadable, of: positions.count) }) {
                break
            }
            let flushed = try reader.flushCache(awayFrom: 0..<first.startLBA, count: cacheFlushSectors)
            let independent =
                flushed || AudioReader.readEvictsItself(sectors: first.startLBA, cacheFlushSectors: cacheFlushSectors)
            incomplete = incomplete || !independent
            let next = try reader.read(positions, withC2: false)
            if independent, next.unreadable.isEmpty,
                reads.contains(where: { $0.unreadable.isEmpty && $0.samples == next.samples })
            {
                if peak(next) < silencePeak { return nil }
                return HiddenTrackRip(samples: next.samples, peak: peak(next), readsAgree: true, reads: reads.count + 1)
            }
            reads.append(next)
        }
        // Keep the best available audio, with the failures explicit, until a later rip can confirm it.
        let best = reads.min { $0.unreadable.count < $1.unreadable.count }!
        // A whole read of silence is silence, as for the first read.
        if best.unreadable.isEmpty && peak(best) < silencePeak { return nil }
        return HiddenTrackRip(
            samples: best.samples, peak: peak(best), readsAgree: false, reads: reads.count,
            unreadableSamples: best.unreadable, cacheFlushIncomplete: incomplete)
    }

    /// The larger of a sample's two 16-bit magnitudes.
    static func magnitude(of sample: UInt32) -> Int {
        let left = Int(Int16(bitPattern: UInt16(sample & 0xFFFF)))
        let right = Int(Int16(bitPattern: UInt16(sample >> 16)))
        return max(abs(left), abs(right))
    }
}
