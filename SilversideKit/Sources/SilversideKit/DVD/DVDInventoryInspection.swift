import Foundation

extension DVDTools {
    func inspectFormats(_ inventory: inout DVDInventory, work: URL, stop: StopToken) throws {
        for index in inventory.presentations.indices {
            var presentation = inventory.presentations[index]
            guard presentation.videoReference == nil else { continue }
            let shared = inventory.presentations[..<index].contains {
                $0.videoReference == nil && $0.titleSet == presentation.titleSet && $0.tracks == presentation.tracks
            }
            let readErrors = presentation.trackFormats ?? []
            var observations = [DVDTrackFormat]()
            for track in presentation.tracks {
                try stop.check()
                var observation = DVDTrackFormat(number: track.number)
                if let reason = readErrors.first(where: { $0.number == track.number })?.unsupportedReason {
                    observation.unsupportedReason = reason
                } else {
                    do {
                        let sample = work.appendingPathComponent(presentation.sampleFile(track: track.number))
                        var (format, _) = try inspect(sample, work: work, stop: stop)
                        if shared && format.codec == "mlp" && format.channels > 2 {
                            // Shared extents may select an authored MLP stereo substream.
                            // Check actual decoded output, never request an output -ac downmix.
                            let preview = sample.appendingPathExtension("stereo.flac")
                            try DVDExtraction.clean(
                                DVDProcess.run(
                                    ffmpeg,
                                    DVDExtraction.common + [
                                        "-downmix", "stereo", "-f", "mpeg", "-i", sample.path, "-t", "0.05",
                                        "-map", "0:a:0", "-af", "asetpts=N/SR/TB", "-c:a", "flac", preview.path,
                                    ], in: work, stop: stop, timeout: 60))
                            (format, _) = try inspect(preview, work: work, stop: stop)
                            guard format.channels == 2, format.layout == "stereo" else {
                                throw DVDError("No authored stereo substream was exposed by the decoder.")
                            }
                            format.codec = "mlp"
                        } else if shared {
                            throw DVDError(
                                "Duplicate reference to an earlier program; select the earlier program instead.")
                        }
                        observation.format = format
                    } catch is CancellationError { throw CancellationError() } catch {
                        observation.unsupportedReason = String(describing: error)
                    }
                }
                observations.append(observation)
            }
            presentation.trackFormats = observations
            presentation.authoredStereo =
                shared && !observations.isEmpty
                && observations.allSatisfy {
                    $0.format?.codec == "mlp" && $0.format?.channels == 2 && $0.unsupportedReason == nil
                }
            presentation.classifyFormats()
            inventory.presentations[index] = presentation
        }
    }
}

extension DVDPresentation {
    /// Retain every observation, including unsupported formats. Only a complete,
    /// uniform set supplies the program-wide format used by the current ripper.
    mutating func classifyFormats() {
        format = nil
        guard var observations = trackFormats, !tracks.isEmpty,
            observations.map(\.number) == tracks.map(\.number)
        else {
            unsupportedReason = unsupportedReason ?? "Incomplete per-track format inventory."
            return
        }
        for index in observations.indices where observations[index].unsupportedReason == nil {
            do {
                guard let found = observations[index].format else { throw DVDError("Audio format is unknown.") }
                guard found.codec == "mlp",
                    [44_100, 48_000, 88_200, 96_000, 176_400, 192_000].contains(found.sampleRate),
                    [16, 24].contains(found.bits),
                    (found.channels == 2 && found.layout == "stereo") || (found.channels == 6 && found.layout == "5.1")
                else { throw DVDError("Extraction currently supports 16/24-bit MLP stereo or 5.1; found \(found).") }
                _ = try tracks[index].frames(at: found.sampleRate)
            } catch {
                observations[index].unsupportedReason = String(describing: error)
            }
        }
        trackFormats = observations
        let known = observations.compactMap(\.format)
        if let first = known.first, known.count == tracks.count, known.allSatisfy({ $0 == first }) {
            format = first
        } else if let first = known.first, known.contains(where: { $0 != first }) {
            unsupportedReason =
                unsupportedReason ?? "Formats change between tracks; extraction currently requires one constant format."
        }
        if let failed = observations.first(where: { $0.unsupportedReason != nil }) {
            unsupportedReason = unsupportedReason ?? "Track \(failed.number): \(failed.unsupportedReason!)"
        }
    }
}
