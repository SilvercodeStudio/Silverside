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

    /// Below this peak, the gap is silence (or dither), not a hidden track.
    public static let silencePeak = 32

    /// Reads the part of the disc before track 1, and returns it if it is audio, not
    /// silence. Nil if track 1 starts at LBA 0, or the gap is silent, or track 1 is a data
    /// track (a mixed-mode disc), which no drive reads as audio.
    public static func rip(reader: AudioReader, cacheFlushSectors: Int = 4000, maximumReads: Int = 4) throws
        -> HiddenTrackRip?
    {
        guard let first = reader.toc.audioTracks.first, first == reader.toc.tracks[0], first.startLBA > 0 else {
            return nil
        }
        let positions = 0..<(first.startLBA * CDDA.samplesPerSector)
        let read = try reader.readSamples(positions)
        let peak = read.reduce(0) { max($0, magnitude(of: $1)) }
        guard peak >= silencePeak else { return nil }

        // Read again, after a cache flush, until two reads agree.
        var reads = [read]
        while reads.count < maximumReads {
            try reader.flushCache(awayFrom: 0..<first.startLBA, count: cacheFlushSectors)
            let next = try reader.readSamples(positions)
            if let match = reads.first(where: { $0 == next }) {
                return HiddenTrackRip(samples: match, peak: peak, readsAgree: true, reads: reads.count + 1)
            }
            reads.append(next)
        }
        return HiddenTrackRip(samples: read, peak: peak, readsAgree: false, reads: reads.count)
    }

    /// The larger of a sample's two 16-bit magnitudes.
    static func magnitude(of sample: UInt32) -> Int {
        let left = Int(Int16(bitPattern: UInt16(sample & 0xFFFF)))
        let right = Int(Int16(bitPattern: UInt16(sample >> 16)))
        return max(abs(left), abs(right))
    }
}
