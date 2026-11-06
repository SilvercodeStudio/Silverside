import Foundation

extension DVDAudioFormat {
    func validateExtraction() throws {
        guard codec == "mlp", [44_100, 48_000, 88_200, 96_000, 176_400, 192_000].contains(sampleRate),
            [16, 24].contains(bits),
            (channels == 2 && layout == "stereo") || (channels == 5 && layout == "5.0")
                || (channels == 6 && layout == "5.1")
        else { throw DVDError("Extraction supports 16/24-bit MLP stereo, 5.0 or 5.1; found \(self).") }
    }
}

extension DVDDecodeRun {
    /// Format changes require a decoder restart demonstrated by navigation.
    /// Never infer a restart merely because a format changes.
    func format(in presentation: DVDPresentation) throws -> DVDAudioFormat {
        guard !tracks.isEmpty else { throw DVDError("Cannot decode an empty run.") }
        let formats = try tracks.map { track in
            if let observations = presentation.trackFormats {
                let matches = observations.filter { $0.number == track.number }
                guard matches.count == 1, let found = matches.first,
                    found.unsupportedReason == nil, let format = found.format
                else { throw DVDError("Track \(track.number): missing or unsupported format observation.") }
                return format
            }
            guard let format = presentation.format else { throw DVDError("Unknown audio format.") }
            return format
        }
        let format = formats[0]
        try format.validateExtraction()
        guard formats.allSatisfy({ $0 == format }) else {
            throw DVDError("Formats change within a continuous run; independent decoding is not established.")
        }
        return format
    }

    /// The cached 44.1 kHz sampler demonstrates rounded durations for independent
    /// cells. Require the full decode to equal this nearest-sample candidate before
    /// publishing. Fractional internal cuts and other rates still need evidence.
    func frameCounts(at rate: Int) throws -> [Int64] {
        try tracks.map { track in
            if rate == 44_100, tracks.count == 1, track.durationPTS > 0,
                track.durationPTS <= (Int64.max - 45_000) / Int64(rate)
            {
                let frames = (track.durationPTS * Int64(rate) + 45_000) / 90_000
                guard frames > 0 else { throw DVDError("Track duration is shorter than one sample.") }
                return frames
            }
            return try track.frames(at: rate)
        }
    }
}

extension DVDPresentation {
    func extractionFormats() throws -> [DVDAudioFormat] {
        try decodingRuns().map { run in
            let format = try run.format(in: self)
            _ = try run.frameCounts(at: format.sampleRate)
            return format
        }
    }

    /// A mixed stereo/surround program requires explicit --title selection.
    var extractionMix: String? {
        guard let formats = try? extractionFormats() else { return nil }
        if formats.allSatisfy({ $0.channels == 2 }) { return "Stereo" }
        if formats.allSatisfy({ $0.channels > 2 }) { return "Surround" }
        return "Mixed"
    }
}
