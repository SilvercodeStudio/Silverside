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
    /// uniform set supplies a program-wide format; mixed programs use run formats.
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
                try found.validateExtraction()
            } catch {
                observations[index].unsupportedReason = String(describing: error)
            }
        }
        trackFormats = observations
        let known = observations.compactMap(\.format)
        if let first = known.first, known.count == tracks.count, known.allSatisfy({ $0 == first }) {
            format = first
        }
        if let failed = observations.first(where: { $0.unsupportedReason != nil }) {
            unsupportedReason = unsupportedReason ?? "Track \(failed.number): \(failed.unsupportedReason!)"
        }
        if unsupportedReason == nil {
            do { _ = try extractionFormats() } catch { unsupportedReason = String(describing: error) }
        }
    }
}
