import CryptoKit
import Darwin
import Foundation

/// This report describes local read/decode checks, not an AccurateRip/CTDB result.
public struct DVDRipReport: Codable, Sendable {
    public var version = 1
    public var silverside = SilversideVersion.described
    public var started = Date()
    public var finished: Date?
    public var status = "incomplete"
    public var error: String?
    /// Scratch data retained after failure or cancellation, relative to the output root.
    public var retainedWork: RetainedWork?
    public var inventory: DVDInventory?
    public var ffmpegVersion: String?
    public var selected = [String]()
    public var programs = [Program]()
    public var limitations = [
        "Local decode and PCM equality checks only; no independent database verification or secure reread consensus.",
        "Only contiguous, one-cell-per-track MLP stereo/5.0/5.1 with a constant format within each decoding run is supported.",
        "No resampling, normalization, ReplayGain, or generic stereo downmix. Authored stereo substreams are identified separately.",
        "Optional DVD-Audio text is not parsed; filenames and title tags are numbered placeholders.",
        "Menus, pictures, downmix instructions and other presentation metadata are not preserved in FLAC.",
    ]

    public struct Program: Codable, Sendable {
        public var id: String
        public var directory: String
        public var sourceSHA256: String
        public var decoderResetPerTrack: Bool
        /// Verified continuous runs; absent in reports written before run-based extraction.
        public var runs: [Run]?
        public var pcmSHA256: String?
        public var complete = false
        public var tracks = [Track]()
    }
    public struct Run: Codable, Sendable {
        public var firstTrack: Int
        public var lastTrack: Int
        public var frames: Int64
        public var pcmSHA256: String
        public var format: DVDAudioFormat?
        public var roundedDuration: Bool?
    }
    public struct Track: Codable, Sendable {
        public var number: Int
        public var file: String
        public var frames: Int64
        public var pcmSHA256: String
        public var fileSHA256: String
        public var format: DVDAudioFormat?
    }
    public struct RetainedWork: Codable, Sendable {
        public var directory: String
        /// Logical file bytes, not allocated disk space. Nil if counting was incomplete.
        public var bytes: Int64?
    }
}

public enum DVDMix: String, CaseIterable, Codable, Sendable {
    case auto, surround, stereo, both
}

public enum DVDExtraction {
    /// Never silently choose among several programs of the requested channel count.
    public static func select(_ inventory: DVDInventory, mix: DVDMix = .auto, title: String? = nil) throws
        -> [DVDPresentation]
    {
        if let title {
            guard let p = inventory.presentations.first(where: { $0.id == title }) else {
                throw DVDError("No DVD program \(title). Run dvd info to list programs.")
            }
            guard p.unsupportedReason == nil, p.extractionMix != nil else {
                throw DVDError(p.unsupportedReason ?? "Unknown audio format.")
            }
            return [p]
        }
        let candidates = inventory.presentations.filter {
            $0.unsupportedReason == nil && $0.extractionMix != nil && !$0.shortProgram
        }
        func one(_ mix: String) throws -> DVDPresentation {
            let found = candidates.filter { $0.extractionMix == mix }
            guard found.count == 1 else {
                throw DVDError(
                    found.isEmpty
                        ? "No supported \(mix.lowercased()) program. Run dvd info to inspect the disc."
                        : "Several \(mix.lowercased()) programs (\(found.map(\.id).joined(separator: ", "))). Select one with --title SET:TITLE."
                )
            }
            return found[0]
        }
        switch mix {
        case .auto: return [try one(candidates.contains { $0.extractionMix == "Surround" } ? "Surround" : "Stereo")]
        case .surround: return [try one("Surround")]
        case .stereo: return [try one("Stereo")]
        case .both: return [try one("Surround"), try one("Stereo")]
        }
    }

    /// The destination must not exist. All media is staged in this newly claimed directory;
    /// tracks are promoted only after format, duration and PCM checks pass.
    public static func rip(
        source: String, output: URL, tools: DVDTools, mix: DVDMix = .auto, title: String? = nil,
        stop: StopToken = StopToken(), progress: @escaping (String) -> Void = { _ in }
    ) throws -> DVDRipReport {
        let root = output.standardizedFileURL.resolvingSymlinksInPath()
        let input = URL(fileURLWithPath: source).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: input.path, isDirectory: &directory), directory.boolValue {
            // Check filesystem identity too: paths can differ only in case on macOS.
            var relationship = FileManager.URLRelationship.other
            try FileManager.default.getRelationship(
                &relationship, ofDirectoryAt: input, toItemAt: root.deletingLastPathComponent())
            if root == input || relationship == .same || relationship == .contains {
                throw DVDError("The output cannot be inside the DVD source directory.")
            }
        }
        guard mkdir(root.path, 0o777) == 0 else {
            throw DVDError(
                "Cannot create a new output directory (the parent must exist, and the output must not): \(root.path). \(String(cString: strerror(errno)))"
            )
        }
        let work = root.appendingPathComponent(".work", isDirectory: true)
        var report = DVDRipReport()
        do {
            try FileManager.default.createDirectory(
                at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try save(report, to: root)
            progress("Inspecting DVD-Audio programs…")
            let inventory = try tools.inventory(source: source, work: work, stop: stop)
            report.inventory = inventory
            report.ffmpegVersion =
                String(
                    decoding: try DVDProcess.run(tools.ffmpeg, ["-version"], in: work, stop: stop).output, as: UTF8.self
                ).components(separatedBy: "\n").first
            let programs = try select(inventory, mix: mix, title: title)
            report.selected = programs.map(\.id)
            try save(report, to: root)
            for presentation in programs {
                try stop.check()
                let folder =
                    "Program \(presentation.titleSet)-\(presentation.title) - \(presentation.extractionMix ?? "Mixed")"
                let destination = root.appendingPathComponent(folder, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                let sourceFile = try readProgram(
                    presentation, source: source, fingerprint: inventory.fingerprint,
                    tools: tools, work: work, stop: stop, progress: progress)
                try validatePackets(sourceFile, presentation: presentation)
                report.programs.append(
                    .init(
                        id: presentation.id, directory: folder, sourceSHA256: try fileHash(sourceFile, stop: stop),
                        decoderResetPerTrack: presentation.resetsDecoder, runs: []))
                let programIndex = report.programs.count - 1
                try save(report, to: root)
                let programWork = work.appendingPathComponent(
                    "program-\(presentation.titleSet)-\(presentation.title)", isDirectory: true)
                try FileManager.default.createDirectory(at: programWork, withIntermediateDirectories: false)
                var staged = [URL]()
                for run in try presentation.decodingRuns() {
                    let decoded = try decodeRun(
                        run, of: presentation, source: sourceFile, tools: tools,
                        work: programWork, stop: stop, progress: progress)
                    report.programs[programIndex].runs?.append(decoded.run)
                    report.programs[programIndex].tracks += decoded.tracks
                    staged += decoded.files
                    try save(report, to: root)
                }
                // Concat demuxing can silently convert changing rates/layouts. A mixed
                // program has verified native PCM hashes per run, no joined PCM hash.
                let formats = try presentation.extractionFormats()
                if let format = formats.first, formats.allSatisfy({ $0 == format }) {
                    report.programs[programIndex].pcmSHA256 = try joinedHash(
                        staged, bits: format.bits, tools: tools, work: programWork, stop: stop)
                }
                try stop.check()
                try publish(staged, tracks: report.programs[programIndex].tracks, to: destination)
                report.programs[programIndex].complete = true
                try save(report, to: root)
                try FileManager.default.removeItem(at: sourceFile)
                try FileManager.default.removeItem(at: programWork)
            }
            try stop.check()
            report.status = "complete"
            report.finished = Date()
            try save(report, to: root)
            try FileManager.default.removeItem(at: work)
            return report
        } catch {
            report.status = error is CancellationError ? "cancelled" : "failed"
            report.error = String(describing: error)
            report.finished = Date()
            if FileManager.default.fileExists(atPath: work.path) {
                report.retainedWork = .init(directory: work.lastPathComponent, bytes: retainedBytes(in: work))
                progress(retainedWorkMessage(report.retainedWork!, root: root))
            }
            try? save(report, to: root)
            throw error
        }
    }

    /// Count regular scratch files without following symbolic links or loading media.
    static func retainedBytes(in directory: URL) -> Int64? {
        var complete = true
        guard
            let entries = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                errorHandler: { _, _ in
                    complete = false
                    return true
                })
        else { return nil }
        var total: Int64 = 0
        for case let file as URL in entries {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            else { return nil }
            if values.isSymbolicLink != true, values.isRegularFile == true {
                guard let size = values.fileSize else { return nil }
                total += Int64(size)
            }
        }
        return complete ? total : nil
    }

    static func retainedWorkMessage(_ work: DVDRipReport.RetainedWork, root: URL) -> String {
        let size = work.bytes.map { "\($0) bytes" } ?? "size unknown"
        return "Retained scratch files: \(root.appendingPathComponent(work.directory).path) (\(size)). "
            + "There is no resume support. After inspecting the failure, you may delete this .work folder; "
            + "keep the reports and any completed program folders."
    }

    static let common = ["-hide_banner", "-v", "warning", "-xerror", "-n", "-nostdin"]
    static func clean(_ result: DVDProcess.Result) throws {
        guard result.diagnostics.isEmpty else {
            throw DVDError("Decoder diagnostics require review: \(result.diagnostics)")
        }
    }
    static func hashValue(_ data: Data) throws -> String {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("SHA256="), text.count == 71, text.dropFirst(7).allSatisfy({ $0.isHexDigit }) else {
            throw DVDError("Invalid decoder PCM hash.")
        }
        return text.dropFirst(7).lowercased()
    }
    static func pcmCodec(_ bits: Int) -> String { bits == 24 ? "pcm_s24le" : "pcm_s16le" }
    static func flacArguments(_ p: DVDPresentation, track: Int? = nil) -> [String] {
        var args = [
            // MLP's 80-sample frames can otherwise become FLAC blocks that Apple's
            // decoder refuses. Reblock without changing PCM or track boundaries.
            "-frame_size", "4096",
            "-c:a", "flac", "-sample_fmt", p.format!.bits == 24 ? "s32" : "s16", "-bits_per_raw_sample",
            String(p.format!.bits), "-map_metadata", "-1",
        ]
        if let track {
            args += [
                "-metadata", String(format: "title=Track %02d", track), "-metadata", "track=\(track)/\(p.tracks.count)",
            ]
        }
        return args
    }
    static func encode(
        _ source: URL, to output: URL, p: DVDPresentation, track: Int? = nil, tools: DVDTools, work: URL,
        stop: StopToken
    ) throws -> String {
        let result = try DVDProcess.run(
            tools.ffmpeg,
            common + (p.authoredStereo ? ["-downmix", "stereo"] : [])
                + ["-reinit_filter", "0", "-f", "mpeg", "-i", source.path, "-map", "0:a:0", "-af", "asetpts=N/SR/TB"]
                + flacArguments(p, track: track) + [
                    output.path, "-map", "0:a:0", "-af", "asetpts=N/SR/TB", "-c:a", pcmCodec(p.format!.bits), "-f",
                    "hash", "-hash", "sha256", "pipe:1",
                ], in: work, stop: stop)
        try clean(result)
        return try hashValue(result.output)
    }
    static func verifyFormat(
        _ file: URL, frames: Int64, format: DVDAudioFormat, tools: DVDTools, work: URL, stop: StopToken
    ) throws {
        let (actual, count) = try tools.inspect(file, work: work, stop: stop)
        var expected = format
        expected.codec = "flac"
        guard actual == expected, count == frames else {
            throw DVDError(
                "\(file.lastPathComponent): format or sample count differs from DVD navigation (expected \(frames), found \(count.map(String.init) ?? "unknown"))."
            )
        }
    }
    static func pcmHash(_ file: URL, bits: Int, tools: DVDTools, work: URL, stop: StopToken) throws -> String {
        let result = try DVDProcess.run(
            tools.ffmpeg,
            common + [
                "-i", file.path, "-map", "0:a:0", "-c:a", pcmCodec(bits), "-f", "hash", "-hash", "sha256", "pipe:1",
            ], in: work, stop: stop)
        try clean(result)
        return try hashValue(result.output)
    }
    static func joinedHash(_ files: [URL], bits: Int, tools: DVDTools, work: URL, stop: StopToken) throws -> String {
        // Generated numeric basenames only; user paths never enter concat syntax.
        let manifest = work.appendingPathComponent("tracks.ffconcat")
        try ("ffconcat version 1.0\n" + files.map { "file '\($0.lastPathComponent)'\n" }.joined()).write(
            to: manifest, atomically: true, encoding: .utf8)
        let result = try DVDProcess.run(
            tools.ffmpeg,
            common + [
                "-f", "concat", "-safe", "1", "-i", manifest.path, "-map", "0:a:0", "-af", "asetpts=N/SR/TB", "-c:a",
                pcmCodec(bits), "-f", "hash", "-hash", "sha256", "pipe:1",
            ], in: work, stop: stop)
        try clean(result)
        return try hashValue(result.output)
    }
    static func split(
        _ full: URL, p: DVDPresentation, tracks selected: [DVDTrack]? = nil, frameCounts supplied: [Int64]? = nil,
        tools: DVDTools, work: URL, stop: StopToken
    ) throws {
        let tracks = selected ?? p.tracks
        let counts = try supplied ?? tracks.map { try $0.frames(at: p.format!.sampleRate) }
        guard counts.count == tracks.count else { throw DVDError("Incomplete run sample counts.") }
        var filters = ["[0:a]asplit=\(tracks.count)" + tracks.indices.map { "[s\($0)]" }.joined()]
        var offset: Int64 = 0
        for (i, count) in counts.enumerated() {
            let (end, overflow) = offset.addingReportingOverflow(count)
            guard count > 0, !overflow else { throw DVDError("Invalid track sample count.") }
            filters.append("[s\(i)]atrim=start_sample=\(offset):end_sample=\(end),asetpts=N/SR/TB[t\(i)]")
            offset = end
        }
        var args = common + ["-i", full.path, "-filter_complex", filters.joined(separator: ";")]
        for (i, track) in tracks.enumerated() {
            args +=
                ["-map", "[t\(i)]"] + flacArguments(p, track: track.number) + [
                    work.appendingPathComponent(String(format: "%02d.flac", track.number)).path
                ]
        }
        try clean(DVDProcess.run(tools.ffmpeg, args, in: work, stop: stop))
    }
    static func fileHash(_ file: URL, stop: StopToken) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try stop.check()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func copyRange(_ source: URL, to output: URL, offset: Int, count: Int, stop: StopToken) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let fd = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DVDError("Cannot create track staging file.") }
        let out = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? out.close() }
        try input.seek(toOffset: UInt64(offset))
        var remaining = count
        while remaining > 0 {
            try stop.check()
            guard let data = try input.read(upToCount: min(remaining, 1024 * 1024)), !data.isEmpty else {
                throw DVDError("Short staged audio read.")
            }
            try out.write(contentsOf: data)
            remaining -= data.count
        }
    }
    static func save(_ report: DVDRipReport, to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: root.appendingPathComponent("dvd-rip.json"), options: .atomic)
        var lines = [
            "Silverside DVD-Audio Rip Report", "Status: \(report.status)",
            "Source: \(report.inventory?.source ?? "not inspected")",
            "Volume: \(report.inventory?.volume ?? "unknown")",
        ]
        if let error = report.error { lines += ["Error: \(error)"] }
        if let work = report.retainedWork { lines += [retainedWorkMessage(work, root: root)] }
        for p in report.programs {
            lines += [
                "", "Program \(p.id): \(p.complete ? "complete" : "incomplete")",
                "Source sectors SHA-256: \(p.sourceSHA256)",
            ]
            if let hash = p.pcmSHA256 { lines += ["Joined PCM SHA-256: \(hash)"] }
            if p.pcmSHA256 == nil, p.complete {
                lines += ["Native formats differ: PCM verified separately for each run; no joined PCM hash."]
            }
            for run in p.runs ?? [] {
                if let format = run.format { lines += ["  Run format: \(format)"] }
                if run.roundedDuration == true {
                    lines += ["  44.1 kHz duration rounded to nearest sample, confirmed by full decode."]
                }
                lines += [
                    "  Continuous run, tracks \(run.firstTrack)–\(run.lastTrack): \(run.frames) frames; PCM SHA-256 \(run.pcmSHA256)"
                ]
            }
            for t in p.tracks { lines += ["  \(t.file): \(t.frames) frames; PCM SHA-256 \(t.pcmSHA256)"] }
        }
        lines += ["", "Limitations:"] + report.limitations.map { "- " + $0 }
        try (lines.joined(separator: "\n") + "\n").write(
            to: root.appendingPathComponent("Rip Report.txt"), atomically: true, encoding: .utf8)
    }
    /// Check the actual first audio packet of each cell against the navigation timestamp.
    static func validatePackets(_ source: URL, presentation p: DVDPresentation) throws {
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        let first = p.tracks[0].firstSector
        for track in p.tracks {
            try file.seek(toOffset: UInt64(track.firstSector - first) * 2048)
            let data = try file.read(upToCount: min(32, track.lastSector - track.firstSector + 1) * 2048) ?? Data()
            guard try firstAudioPTS(data) == track.startPTS else {
                throw DVDError("Track \(track.number): audio packet timestamp disagrees with navigation.")
            }
        }
    }
    static func firstAudioPTS(_ data: Data) throws -> Int64 {
        let b = Array(data)
        for base in stride(from: 0, to: b.count - 2047, by: 2048) {
            guard b[base..<base + 4].elementsEqual([0, 0, 1, 0xba]) else { continue }
            var pos = base + 14 + Int(b[base + 13] & 7)
            while pos + 9 <= base + 2048, b[pos..<pos + 3].elementsEqual([0, 0, 1]) {
                let end = pos + 6 + Int(b[pos + 4]) * 256 + Int(b[pos + 5])
                guard end <= base + 2048, end > pos else { throw DVDError("Invalid DVD audio packet length.") }
                if b[pos + 3] == 0xbd, b[pos + 7] & 0x80 != 0 {
                    guard end >= pos + 14, b[pos + 8] >= 5, b[pos + 6] & 0x30 == 0 else {
                        throw DVDError("Encrypted or truncated audio timestamp.")
                    }
                    let a = Array(b[pos + 9..<pos + 14])
                    guard [0, 2, 4].allSatisfy({ a[$0] & 1 == 1 }) else {
                        throw DVDError("Invalid audio timestamp marker.")
                    }
                    return Int64(a[0] >> 1 & 7) << 30 | Int64(a[1]) << 22 | Int64(a[2] >> 1) << 15 | Int64(a[3]) << 7
                        | Int64(a[4] >> 1)
                }
                pos = end
            }
        }
        throw DVDError("No audio timestamp in the first 32 sectors of a cell.")
    }
}
