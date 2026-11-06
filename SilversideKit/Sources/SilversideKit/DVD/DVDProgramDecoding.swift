import Foundation

extension DVDExtraction {
    static func readProgram(
        _ presentation: DVDPresentation, source: String, fingerprint: String,
        tools: DVDTools, work: URL, stop: StopToken, progress: @escaping (String) -> Void
    ) throws -> URL {
        let file = work.appendingPathComponent("program-\(presentation.titleSet)-\(presentation.title).aob")
        let first = presentation.tracks[0].firstSector
        let count = presentation.tracks.last!.lastSector - first + 1
        progress("Reading program \(presentation.id): \(count) sectors, \(presentation.tracks.count) tracks…")
        _ = try DVDProcess.run(
            tools.helper,
            [
                "read", source, String(presentation.titleSet), String(first), String(count), file.path,
                fingerprint, "protocol-2",
            ], in: work, stop: stop,
            progress: {
                if let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber {
                    progress("Program \(presentation.id): read \(bytes.int64Value / 2048)/\(count) sectors")
                }
            })
        guard
            (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
                == Int64(count) * 2048
        else { throw DVDError("Incomplete audio read.") }
        return file
    }

    /// Decode one continuous run with fresh state. All cuts use cumulative sample
    /// counts within that run, never its restarted absolute timestamp. Nothing is
    /// published until every run in the program has passed verification.
    static func decodeRun(
        _ run: DVDDecodeRun, of presentation: DVDPresentation, source: URL,
        tools: DVDTools, work: URL, stop: StopToken, progress: (String) -> Void
    ) throws -> (run: DVDRipReport.Run, tracks: [DVDRipReport.Track], files: [URL]) {
        try stop.check()
        guard let first = run.tracks.first, let last = run.tracks.last, let format = presentation.format else {
            throw DVDError("Cannot decode an empty run or unknown format.")
        }
        let runWork = work.appendingPathComponent("run-\(first.number)", isDirectory: true)
        try FileManager.default.createDirectory(at: runWork, withIntermediateDirectories: false)
        let input: URL
        if run.tracks == presentation.tracks {
            input = source
        } else {
            input = runWork.appendingPathComponent("source.aob")
            try copyRange(
                source, to: input, offset: (first.firstSector - presentation.tracks[0].firstSector) * 2048,
                count: (last.lastSector - first.firstSector + 1) * 2048, stop: stop)
        }
        // A new run may begin with a different format. Refuse it before a decoder
        // could convert it to the first run's precision or speaker layout.
        var (sourceFormat, _) = try tools.inspect(input, work: runWork, stop: stop)
        if presentation.authoredStereo, sourceFormat.channels == 6, sourceFormat.layout == "5.1" {
            sourceFormat.channels = 2
            sourceFormat.layout = "stereo"
        }
        guard sourceFormat == format else {
            throw DVDError("Track \(first.number): run format differs from the selected program (\(sourceFormat)).")
        }
        progress("Program \(presentation.id): decoding continuous run, tracks \(first.number)–\(last.number)…")
        let continuous = runWork.appendingPathComponent("continuous.flac")
        let sourceHash = try encode(input, to: continuous, p: presentation, tools: tools, work: runWork, stop: stop)
        let frames = try run.tracks.reduce(Int64(0)) { try $0 + $1.frames(at: format.sampleRate) }
        try verifyFormat(continuous, frames: frames, format: format, tools: tools, work: runWork, stop: stop)
        guard try pcmHash(continuous, bits: format.bits, tools: tools, work: runWork, stop: stop) == sourceHash else {
            throw DVDError("Run starting at track \(first.number): FLAC differs from source PCM.")
        }
        try split(continuous, p: presentation, tracks: run.tracks, tools: tools, work: work, stop: stop)
        var tracks = [DVDRipReport.Track]()
        var files = [URL]()
        for track in run.tracks {
            try stop.check()
            progress("Program \(presentation.id): checking track \(track.number)/\(presentation.tracks.count)…")
            let file = work.appendingPathComponent(String(format: "%02d.flac", track.number))
            let frames = try track.frames(at: format.sampleRate)
            try verifyFormat(file, frames: frames, format: format, tools: tools, work: work, stop: stop)
            tracks.append(
                .init(
                    number: track.number, file: String(format: "%02d - Track %02d.flac", track.number, track.number),
                    frames: frames,
                    pcmSHA256: try pcmHash(file, bits: format.bits, tools: tools, work: work, stop: stop),
                    fileSHA256: try fileHash(file, stop: stop)))
            files.append(file)
        }
        let joined = try joinedHash(files, bits: format.bits, tools: tools, work: work, stop: stop)
        guard joined == sourceHash else {
            throw DVDError("Joined tracks differ from the source PCM of the run starting at track \(first.number).")
        }
        try FileManager.default.removeItem(at: runWork)
        return (
            .init(firstTrack: first.number, lastTrack: last.number, frames: frames, pcmSHA256: joined), tracks, files
        )
    }

    static func publish(_ files: [URL], tracks: [DVDRipReport.Track], to destination: URL) throws {
        for (file, track) in zip(files, tracks) {
            try FileManager.default.moveItem(at: file, to: destination.appendingPathComponent(track.file))
        }
        let playlist = "#EXTM3U\n" + tracks.map(\.file).joined(separator: "\n") + "\n"
        try playlist.write(to: destination.appendingPathComponent("Tracks.m3u8"), atomically: true, encoding: .utf8)
    }
}
