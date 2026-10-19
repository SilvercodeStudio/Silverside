@testable import CDRipKit

/// A small, fast pseudo-random generator, so test images are the same on every run.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// An audio-only disc image with random samples.
func makeDisc(trackSectors: [Int], seed: UInt64 = 1) throws -> (toc: TOC, samples: [UInt32]) {
    var starts = [Int]()
    var lba = 0
    for count in trackSectors {
        starts.append(lba)
        lba += count
    }
    let toc = try TOC(audioTrackStarts: starts, leadOutLBA: lba)
    var generator = SplitMix64(state: seed)
    let samples = (0..<(lba * CDDA.samplesPerSector)).map { _ in UInt32.random(in: .min ... .max, using: &generator) }
    return (toc, samples)
}

extension TOC {
    /// Makes a TOC from MusicBrainz offsets, which include the 150-sector lead-in.
    init(musicBrainzOffsets offsets: [Int], sectors: Int) throws {
        try self.init(
            audioTrackStarts: offsets.map { $0 - CDDA.leadInSectors }, leadOutLBA: sectors - CDDA.leadInSectors)
    }
}
