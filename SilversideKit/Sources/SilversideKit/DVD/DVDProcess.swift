import Darwin
import Foundation

/// Bounded child execution with file-backed diagnostics: no pipe can fill and deadlock
/// the other stream. Cancellation terminates the child and escalates after two seconds.
enum DVDProcess {
    struct Result {
        var output: Data
        var diagnostics: String
    }

    static func run(
        _ executable: URL, _ arguments: [String], in work: URL, stop: StopToken,
        timeout: TimeInterval = 3600, progress: (() -> Void)? = nil
    ) throws -> Result {
        try stop.check()
        let tag = UUID().uuidString
        let outURL = work.appendingPathComponent("process-\(tag).stdout")
        let errURL = work.appendingPathComponent("process-\(tag).stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outURL)
        let errors = try FileHandle(forWritingTo: errURL)
        defer {
            try? output.close()
            try? errors.close()
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "DVDCSS_VERBOSE")
        environment["DVDCSS_CACHE"] = "off"
        process.environment = environment
        try process.run()
        let started = Date()
        var stopping: Date?
        var lastProgress = Date.distantPast
        while process.isRunning {
            if stop.isStopped || Date().timeIntervalSince(started) > timeout {
                if stopping == nil {
                    process.terminate()
                    stopping = Date()
                } else if Date().timeIntervalSince(stopping!) > 2 {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            if Date().timeIntervalSince(lastProgress) >= 2 {
                progress?()
                lastProgress = Date()
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        try stop.check()
        if stopping != nil { throw DVDError("\(executable.lastPathComponent) timed out. Diagnostics: \(errURL.path)") }
        let errorsReader = try FileHandle(forReadingFrom: errURL)
        defer { try? errorsReader.close() }
        let errorSize = try errorsReader.seekToEnd()
        try errorsReader.seek(toOffset: errorSize > 32 * 1024 ? errorSize - 32 * 1024 : 0)
        let stderr = try errorsReader.readToEnd() ?? Data()
        let diagnostic = String(decoding: stderr, as: UTF8.self)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw DVDError("\(executable.lastPathComponent) failed (\(process.terminationStatus)). \(diagnostic)")
        }
        guard (try outURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 16 * 1024 * 1024 else {
            throw DVDError("Oversized helper/probe response.")
        }
        let data = try Data(contentsOf: outURL)
        // Retain diagnostics for the rip report/debugging; remove only this invocation's empty files.
        try? FileManager.default.removeItem(at: outURL)
        if stderr.isEmpty { try? FileManager.default.removeItem(at: errURL) }
        return Result(output: data, diagnostics: diagnostic)
    }
}

public struct DVDTools: Sendable {
    public let helper: URL
    public let ffmpeg: URL
    public let ffprobe: URL

    init(helper: URL, ffmpeg: URL, ffprobe: URL) {
        self.helper = helper
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }

    public init() throws {
        let environment = ProcessInfo.processInfo.environment
        let helperURL =
            environment["SILVERSIDE_DVD_HELPER"].map { URL(fileURLWithPath: $0) }
            ?? (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("silverside-dvd-helper")
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw DVDError(
                "DVD support needs silverside-dvd-helper beside the CLI. Build/install both with make cli or make install."
            )
        }
        guard let ffmpeg = FFmpeg.program() else {
            throw DVDError("DVD decoding needs ffmpeg. Install with: brew install ffmpeg libdvdread")
        }
        let probe =
            environment["SILVERSIDE_FFPROBE"].map { URL(fileURLWithPath: $0) }
            ?? ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: probe.path) else {
            throw DVDError("DVD inspection needs ffprobe from the ffmpeg Homebrew package.")
        }
        helper = helperURL
        self.ffmpeg = ffmpeg
        ffprobe = probe
    }

    func inspect(_ file: URL, work: URL, stop: StopToken, stereo: Bool = false) throws -> (DVDAudioFormat, Int64?) {
        let result = try DVDProcess.run(
            ffprobe,
            ["-v", "error"] + (stereo ? ["-downmix", "stereo"] : [])
                + ["-show_streams", "-of", "json", file.path], in: work, stop: stop, timeout: 60)
        struct Probe: Decodable { var streams: [Stream] }
        struct Stream: Decodable {
            var codecName: String?
            var codecType: String?
            var sampleRate: String?
            var bitsPerRawSample: String?
            var channels: Int?
            var channelLayout: String?
            var durationTs: Int64?
            var timeBase: String?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let streams = try decoder.decode(Probe.self, from: result.output).streams.filter {
            $0.codecType == "audio"
        }
        guard streams.count == 1, let stream = streams.first, let rate = Int(stream.sampleRate ?? ""),
            let bits = Int(stream.bitsPerRawSample ?? ""), let channels = stream.channels,
            let layout = stream.channelLayout, let codec = stream.codecName, result.diagnostics.isEmpty
        else {
            throw DVDError(
                "Cannot determine a unique audio format for \(file.lastPathComponent). \(result.diagnostics)")
        }
        let format = DVDAudioFormat(codec: codec, sampleRate: rate, bits: bits, channels: channels, layout: layout)
        return (format, stream.timeBase == "1/\(rate)" ? stream.durationTs : nil)
    }

    public func inventory(source: String, work: URL, stop: StopToken = StopToken()) throws -> DVDInventory {
        let result = try DVDProcess.run(helper, ["inventory", source, work.path], in: work, stop: stop, timeout: 300)
        var inventory = try JSONDecoder().decode(DVDInventory.self, from: result.output)
        guard inventory.protocolVersion == 1 else { throw DVDError("Unsupported DVD helper protocol version.") }
        for index in inventory.presentations.indices {
            let p = inventory.presentations[index]
            guard p.unsupportedReason == nil else { continue }
            do {
                let sample = work.appendingPathComponent(p.sampleFile)
                var (format, _) = try inspect(sample, work: work, stop: stop)
                // A repeated reference to the same extents may expose an authored MLP
                // stereo substream. Probe it explicitly; never use an output -ac 2 downmix.
                let shared = inventory.presentations[..<index].contains {
                    $0.titleSet == p.titleSet && $0.tracks == p.tracks
                }
                if shared && format.codec == "mlp" && format.channels > 2 {
                    // ffprobe's stream header may still describe the full stream even
                    // when the decoder selects two channels. Inspect actual decoded output.
                    let preview = work.appendingPathComponent("stereo-\(p.titleSet)-\(p.title).flac")
                    try DVDExtraction.clean(
                        DVDProcess.run(
                            ffmpeg,
                            DVDExtraction.common + [
                                "-downmix", "stereo", "-f", "mpeg", "-i", sample.path, "-t", "0.05", "-map", "0:a:0",
                                "-af", "asetpts=N/SR/TB", "-c:a", "flac", preview.path,
                            ], in: work, stop: stop, timeout: 60))
                    (format, _) = try inspect(preview, work: work, stop: stop)
                    guard format.channels == 2 else {
                        throw DVDError("No authored stereo substream was exposed by the decoder.")
                    }
                    format.codec = "mlp"
                    inventory.presentations[index].authoredStereo = true
                } else if shared {
                    throw DVDError("Duplicate reference to an earlier program; select the earlier program instead.")
                }
                inventory.presentations[index].format = format
                guard format.codec == "mlp",
                    [44_100, 48_000, 88_200, 96_000, 176_400, 192_000].contains(format.sampleRate),
                    [16, 24].contains(format.bits),
                    (format.channels == 2 && format.layout == "stereo")
                        || (format.channels == 6 && format.layout == "5.1")
                else {
                    throw DVDError(
                        "This initial DVD command supports equal-rate 16/24-bit MLP in stereo or 5.1; found \(format).")
                }
                for track in p.tracks { _ = try track.frames(at: format.sampleRate) }
            } catch is CancellationError { throw CancellationError() } catch {
                inventory.presentations[index].unsupportedReason = String(describing: error)
            }
        }
        return inventory
    }
}
