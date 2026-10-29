import Foundation

/// A DTS-CD's audio: in place of PCM, its tracks hold a DTS Coherent Acoustics stream, often
/// 5.1 surround sound, for a player or receiver with a DTS decoder. Without one, the stream
/// plays as loud static. It rips bit for bit like any audio, and AccurateRip and CTDB know such
/// discs, so the rip is checked as usual; only the encoding needs to know.
///
/// The stream is packed into the 16-bit words of the audio. A DTS-CD packs 14 bits into each
/// word, so the stream's bytes never look like a full-scale click (*Marvin Gaye, Forever Yours*:
/// a frame of 1,024 samples every 4,096 bytes, its sync words at the same place in each). The
/// frames run on across the tracks' starts, as one stream from the first track to the last.
public enum DTSStream {
    /// How the stream sits in the audio's 16-bit words.
    public enum Packing: Sendable {
        /// 14 bits a word, little-endian, as DTS-CDs have it.
        case words14LE
        case words14BE
        /// 16 bits a word.
        case words16LE
        case words16BE
    }

    /// The frames of a stream in some audio: the byte where each starts, at a steady spacing.
    public struct Frames: Equatable, Sendable {
        public var packing: Packing
        /// The bytes from one frame's start to the next's.
        public var spacing: Int
        /// Each frame's first byte, in order. A frame is whole: its bytes are in the audio,
        /// and no other stream starts among them.
        public var starts: [Int]
    }

    /// Frames at a steady spacing that make a track a DTS stream: about a third of a second
    /// at a DTS-CD's spacing. A sync word in music is a chance of one in 2³², and a steady
    /// run of them is none.
    public static let minimumFrames = 16

    /// True if the audio (Silverside samples, as ripped) holds a DTS stream: at least
    /// `minimumFrames` frames at a steady spacing. A player that looks at a second of audio
    /// asks for fewer.
    public static func isStream(_ samples: [UInt32], minimumFrames: Int = minimumFrames) -> Bool {
        samples.withUnsafeBytes { frames(in: $0).map { $0.starts.count >= minimumFrames } ?? false }
    }

    /// The frames of a DTS stream in the bytes, or nil if there are none. A sync word that no
    /// frame follows at the spacing is music that looks like one by chance, and is left out.
    static func frames(in bytes: UnsafeRawBufferPointer) -> Frames? {
        guard let (packing, syncs) = syncWords(in: bytes), syncs.count >= 2 else { return nil }
        // The spacing that most of the gaps between sync words have.
        var gaps = [Int: Int]()
        for (first, second) in zip(syncs, syncs.dropFirst()) { gaps[second - first, default: 0] += 1 }
        guard let spacing = gaps.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key
        else { return nil }
        // Runs of sync words at the spacing. A run of one is a chance match in the frame data.
        let all = Set(syncs)
        var inRun = Set<Int>()
        var runs = [[Int]]()
        for sync in syncs where !inRun.contains(sync) {
            var run = [sync]
            while all.contains(run.last! + spacing) { run.append(run.last! + spacing) }
            inRun.formUnion(run)
            if run.count >= 2 { runs.append(run) }
        }
        let runStarts = runs.map { $0[0] }.sorted()
        // A frame ends where its run's next frame starts; it is cut short when another run
        // starts first (the stream begins again there), or when the audio ends.
        var starts = [Int]()
        for run in runs {
            for start in run {
                let end = start + spacing
                guard end <= bytes.count else { continue }
                let next = runStarts.first { $0 > start }
                if let next, next < end { continue }
                starts.append(start)
            }
        }
        starts.sort()
        return starts.isEmpty ? nil : Frames(packing: packing, spacing: spacing, starts: starts)
    }

    /// The byte of each sync word, at the start of a 16-bit word, for the packing that has the
    /// most. Nil if there is none.
    static func syncWords(in bytes: UnsafeRawBufferPointer) -> (Packing, [Int])? {
        var found: [Packing: [Int]] = [:]
        let count = bytes.count
        var index = 0
        while index + 6 <= count {
            switch (bytes[index], bytes[index + 1]) {
            case (0xFF, 0x1F):
                if bytes[index + 2] == 0x00, bytes[index + 3] == 0xE8, bytes[index + 4] & 0xF0 == 0xF0,
                    bytes[index + 5] == 0x07
                {
                    found[.words14LE, default: []].append(index)
                }
            case (0x1F, 0xFF):
                if bytes[index + 2] == 0xE8, bytes[index + 3] == 0x00, bytes[index + 4] == 0x07,
                    bytes[index + 5] & 0xF0 == 0xF0
                {
                    found[.words14BE, default: []].append(index)
                }
            case (0xFE, 0x7F):
                if bytes[index + 2] == 0x01, bytes[index + 3] == 0x80 { found[.words16LE, default: []].append(index) }
            case (0x7F, 0xFE):
                if bytes[index + 2] == 0x80, bytes[index + 3] == 0x01 { found[.words16BE, default: []].append(index) }
            default: break
            }
            index += 2
        }
        return found.max { $0.value.count < $1.value.count }.map { ($0.key, $0.value) }
    }

    /// What a frame's header says about the source audio.
    struct Header: Equatable {
        /// The bits of the PCM that the stream was made from: 16, 20, or 24.
        var sourceBits: Int
    }

    /// The core header of the frame at `start`. Nil if its bytes are too few.
    static func header(at start: Int, in bytes: UnsafeRawBufferPointer, packing: Packing) -> Header? {
        // The header's bits, in order, from the words that hold them.
        var bits = [Bool]()
        var index = start
        while bits.count < 128, index + 1 < bytes.count {
            let (high, low) = (UInt16(bytes[index]), UInt16(bytes[index + 1]))
            switch packing {
            case .words14LE: bits += (0..<14).reversed().map { (low << 8 | high) >> $0 & 1 == 1 }
            case .words14BE: bits += (0..<14).reversed().map { (high << 8 | low) >> $0 & 1 == 1 }
            case .words16LE: bits += (0..<16).reversed().map { (low << 8 | high) >> $0 & 1 == 1 }
            case .words16BE: bits += (0..<16).reversed().map { (high << 8 | low) >> $0 & 1 == 1 }
            }
            index += 2
        }
        guard bits.count >= 128 else { return nil }
        var position = 0
        func take(_ count: Int) -> Int {
            defer { position += count }
            return bits[position..<(position + count)].reduce(0) { $0 << 1 | ($1 ? 1 : 0) }
        }
        // The sync word, the frame type, the deficit samples, and whether a CRC follows the header.
        _ = take(32 + 1 + 5)
        let crcPresent = take(1) == 1
        // Blocks, frame size, channels, rate, bit rate, five flags, the extension (3 bits and a
        // flag), the subframe flag, the LFE, and the history flag.
        _ = take(7 + 14 + 6 + 4 + 5 + 5 + 4 + 1 + 2 + 1)
        if crcPresent { _ = take(16) }
        // The interpolator, the encoder's version, and the copy history; then the source's resolution.
        _ = take(1 + 4 + 2)
        let resolution = take(3)
        return Header(sourceBits: resolution >= 5 ? 24 : resolution >= 2 ? 20 : 16)
    }

    /// The tags for a DTS-CD's files: MEDIA=DTS CD, as MusicBrainz names the medium, and
    /// DTS=decoded for files that hold the decode.
    public static func tags(decoded: Bool) -> [(key: String, value: String)] {
        [("MEDIA", "DTS CD")] + (decoded ? [("DTS", "decoded")] : [])
    }
}

/// Whether a rip's tracks hold a DTS stream.
public enum DTSStatus: String, Codable, Sendable {
    /// No track does.
    case noStream
    /// Some tracks do, or all of them: each track's `dts` says which.
    case stream

    public init(_ tracks: [RipReport.Track]) {
        self = tracks.contains { $0.dts == true } ? .stream : .noStream
    }
}

/// What to do with a disc whose tracks hold a DTS stream.
public enum DTSChoice: String, Codable, CaseIterable, Sendable {
    /// The app asks when such a disc is about to be encoded; the command line asks at a
    /// terminal, and keeps the stream otherwise.
    case ask
    /// The album as the disc has it, and a decoded copy beside it, "… (DTS 5.1)".
    case decode
    /// The decoded album only.
    case decodeOnly = "decode-only"
    /// The album as the disc has it: the stream, bit for bit, for a DTS decoder.
    case keep
}

/// Decodes DTS with the external `ffmpeg` program. Apple's frameworks have no DTS decoder, and
/// running FFmpeg as a separate program keeps its code out of Silverside, as `lame` is for MP3.
public enum FFmpeg {
    /// The `ffmpeg` program: on the PATH, or where Homebrew puts it. Nil if it is not installed.
    /// The environment variable `SILVERSIDE_FFMPEG` can name another one, or with `none` act as
    /// if there were none, to try what people without it see.
    public static func program() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let chosen = environment["SILVERSIDE_FFMPEG"], !chosen.isEmpty {
            guard chosen != "none", FileManager.default.isExecutableFile(atPath: chosen) else { return nil }
            return URL(filePath: chosen)
        }
        let path = environment["PATH"] ?? ""
        let folders = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        return folders.map { URL(filePath: $0).appending(path: "ffmpeg") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// "FFmpeg 9.0.2", from `ffmpeg -version`. Nil if it does not answer as FFmpeg does.
    public static func version(of ffmpeg: URL) -> String? {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // "ffmpeg version 9.0.2 Copyright (c) 2000-2026 the FFmpeg developers"
        let words = (String(decoding: data, as: UTF8.self).split(separator: "\n").first ?? "").split(separator: " ")
        guard words.count >= 3, words[0] == "ffmpeg", words[1] == "version" else { return nil }
        return "FFmpeg \(words[2])"
    }

    /// Decodes whole DTS frames, one after another, into 32-bit audio, through `ffmpeg`.
    static func decodeDTS(_ stream: Data, ffmpeg: URL) throws -> SurroundPCM {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-f", "dts", "-i", "pipe:0", "-c:a", "pcm_s32le", "-f", "wav",
            "-bitexact", "pipe:1",
        ]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // A write to a pipe whose reader has exited must fail, not end this whole process with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let said = CollectedOutput()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { said.append(data) }
        }
        try process.run()
        // The stream goes in on a thread of its own, while this one reads the audio, so that
        // neither pipe can fill up and stop the other.
        let writer = input.fileHandleForWriting
        let written = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? writer.write(contentsOf: stream)
            try? writer.close()
            written.signal()
        }
        let wave = output.fileHandleForReading.readDataToEndOfFile()
        written.wait()
        process.waitUntilExit()
        errors.fileHandleForReading.readabilityHandler = nil
        said.append(errors.fileHandleForReading.readDataToEndOfFile())
        guard process.terminationStatus == 0 else {
            throw DTSError.ffmpegFailed(
                status: process.terminationStatus, message: String(decoding: said.data, as: UTF8.self))
        }
        return try SurroundPCM(wave: wave)
    }

    /// What a program wrote to a pipe, collected from any thread.
    private final class CollectedOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var collected = Data()

        func append(_ more: Data) {
            lock.withLock { collected.append(more) }
        }

        var data: Data { lock.withLock { collected } }
    }
}

extension SurroundPCM {
    /// The audio of a WAV file of 32-bit samples, as `ffmpeg` writes one to a pipe: its sizes
    /// may be unknown (0 or 0xFFFFFFFF), so the data runs to the end.
    init(wave: Data) throws {
        self = try wave.withUnsafeBytes { bytes in
            func word(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
            func long(_ at: Int) -> Int { word(at) | word(at + 2) << 16 }
            guard bytes.count >= 12, Array(bytes[0..<4]) == Array("RIFF".utf8),
                Array(bytes[8..<12]) == Array("WAVE".utf8)
            else { throw DTSError.unexpectedDecode("not a WAV file") }
            var index = 12
            var channels = 0
            var mask: UInt32?
            while index + 8 <= bytes.count {
                let id = String(decoding: bytes[index..<(index + 4)], as: UTF8.self)
                let size = long(index + 4)
                if id == "fmt ", index + 8 + 16 <= bytes.count {
                    channels = word(index + 10)
                    guard word(index + 22) == 32 else { throw DTSError.unexpectedDecode("not 32-bit samples") }
                    // WAVE_FORMAT_EXTENSIBLE names the channels.
                    if word(index + 8) == 0xFFFE, size >= 40 { mask = UInt32(long(index + 8 + 20)) }
                }
                if id == "data" {
                    guard channels > 0 else { throw DTSError.unexpectedDecode("no format before the audio") }
                    let start = index + 8
                    let end = size == 0 || start + size > bytes.count ? bytes.count : start + size
                    let count = (end - start) / 4 / channels * channels
                    var values = [Int32](repeating: 0, count: count)
                    values.withUnsafeMutableBytes {
                        $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[start..<(start + count * 4)]))
                    }
                    return SurroundPCM(
                        values: values, channels: channels,
                        channelMask: mask ?? SurroundPCM.standardMask(channels: channels))
                }
                index += 8 + size + (size & 1)
            }
            throw DTSError.unexpectedDecode("no audio")
        }
    }
}

/// Decodes the DTS stream of a track into its surround audio, sample for sample in the track's
/// place on the disc: each frame's audio goes where the frame is, as a player that plays the
/// disc straight through has it, so the tracks are gapless.
public struct DTSDecoder: Sendable {
    public var ffmpeg: URL

    public init(ffmpeg: URL) {
        self.ffmpeg = ffmpeg
    }

    /// The frames that settle the decoder before the first frame it keeps, as
    /// `HDCDCodes.decode(previous:)` does for HDCD: its state lasts about 15 frames (on
    /// *Forever Yours*, a decode started 4 frames early was up to 105 steps of 20 bits off).
    static let warmUpFrames = 16

    /// The audio before and after a track that the decode reads: the warm-up, and the frame
    /// that runs across the track's start, at a DTS-CD's 1,024 samples a frame.
    static let contextFrames = 18 * 1024

    /// Decodes the track's stream. `previous` and `next` are the audio just before and after
    /// the track on the disc, if the encoding has those tracks: frames run across a track's
    /// start, and without them the first and last 23 ms or so of the track would be silent.
    /// The values are cut to 20 bits, the resolution of a DTS-CD's source audio, or to 24
    /// when the stream says its source had 24.
    public func decode(
        _ samples: [UInt32], previous: ArraySlice<UInt32>?, next: ArraySlice<UInt32>?
    ) throws -> SurroundPCM {
        let ffmpeg = self.ffmpeg
        return try Self.decode(samples, previous: previous, next: next) { try FFmpeg.decodeDTS($0, ffmpeg: ffmpeg) }
    }

    /// The decode, with `decodeFrames` turning whole frames into their audio: `ffmpeg`, or a
    /// stand-in in tests.
    static func decode(
        _ samples: [UInt32], previous: ArraySlice<UInt32>?, next: ArraySlice<UInt32>?,
        frames decodeFrames: (Data) throws -> SurroundPCM
    ) throws -> SurroundPCM {
        let before = previous.map { Array($0.suffix(contextFrames)) } ?? []
        let after = next.map { Array($0.prefix(contextFrames)) } ?? []
        let audio = before + samples + after
        let trackStart = before.count
        let trackEnd = trackStart + samples.count
        return try audio.withUnsafeBytes { bytes in
            guard let frames = DTSStream.frames(in: bytes) else { throw DTSError.unexpectedDecode("no DTS frames") }
            // Each frame's audio fills the time the frame takes on the disc.
            guard frames.spacing % 4 == 0 else { throw DTSError.unexpectedDecode("frames of \(frames.spacing) bytes") }
            let framesPerFrame = frames.spacing / 4
            let warmUp = Self.warmUpFrames * framesPerFrame
            let bits =
                DTSStream.header(at: frames.starts[0], in: bytes, packing: frames.packing)?.sourceBits == 24 ? 24 : 20
            let mask = ~Int32((1 << (32 - bits)) - 1)
            // The frames that the track needs, from the warm-up on, in runs of frames that follow
            // each other: each run is one decode.
            let needed = frames.starts.filter { start in
                let first = start / 4
                return first + framesPerFrame > trackStart - warmUp && first < trackEnd
            }
            var runs = [[Int]]()
            for start in needed {
                if let last = runs.last?.last, last + frames.spacing == start {
                    runs[runs.count - 1].append(start)
                } else {
                    runs.append([start])
                }
            }
            var result: SurroundPCM?
            var lastError: (any Error)?
            /// Decodes the run's frames and puts the audio of those from `keep` on in its place.
            /// A frame that does not decode (the last one on *Forever Yours* is cut short) makes
            /// the decode short, with no sign of which it was. The last frame is the usual one, so
            /// the run is decoded again without it first; else each half is, the second after a
            /// warm-up, down to the frame, which stays silent.
            func place(_ run: ArraySlice<Int>, keep: Int) throws {
                if try attempt(run, keep: keep) { return }
                if run.endIndex - keep > 1, try attempt(run.dropLast(), keep: keep) { return }
                if run.endIndex - keep == 1 {
                    if run.startIndex < keep { _ = try attempt(run[keep...], keep: keep) }
                    return
                }
                let middle = (keep + run.endIndex) / 2
                try place(run[run.startIndex..<middle], keep: keep)
                try place(run[max(run.startIndex, middle - Self.warmUpFrames)...], keep: middle)
            }
            /// Decodes the run, and puts the audio in place if every frame decoded.
            func attempt(_ run: ArraySlice<Int>, keep: Int) throws -> Bool {
                let data = Data(UnsafeRawBufferPointer(rebasing: bytes[run.first!..<(run.last! + frames.spacing)]))
                var decoded: SurroundPCM?
                do {
                    decoded = try decodeFrames(data)
                } catch let error as DTSError {
                    // ffmpeg stops with an error when no frame decodes at all.
                    lastError = error
                }
                guard let decoded, decoded.frameCount == run.count * framesPerFrame else { return false }
                if result == nil {
                    result = SurroundPCM(
                        values: [Int32](repeating: 0, count: samples.count * decoded.channels),
                        channels: decoded.channels, channelMask: decoded.channelMask, bits: bits)
                }
                guard decoded.channels == result!.channels else {
                    throw DTSError.unexpectedDecode("\(decoded.channels) channels after \(result!.channels)")
                }
                // The audio of the frames kept, from the run's first frame's place, inside the track.
                let channels = decoded.channels
                let first = run.first! / 4
                let from = max(run[keep] / 4, trackStart)
                let to = min(first + decoded.frameCount, trackEnd)
                guard from < to else { return true }
                decoded.values.withUnsafeBufferPointer { source in
                    result!.values.withUnsafeMutableBufferPointer { target in
                        for frame in from..<to {
                            let (s, t) = ((frame - first) * channels, (frame - trackStart) * channels)
                            for channel in 0..<channels { target[t + channel] = source[s + channel] & mask }
                        }
                    }
                }
                return true
            }
            for run in runs { try place(run[...], keep: 0) }
            if result == nil, let lastError { throw lastError }
            guard let result else { throw DTSError.unexpectedDecode("no DTS frames in the track") }
            return result
        }
    }
}

public enum DTSError: Error, Equatable, CustomStringConvertible {
    case ffmpegNotFound
    case ffmpegFailed(status: Int32, message: String)
    case unexpectedDecode(String)
    /// A lossy format would turn the stream into noise.
    case lossyStream(AudioFormat)
    /// The format cannot hold more than two channels here.
    case noSurround(AudioFormat)

    public var description: String {
        switch self {
        case .ffmpegNotFound: "Decoding DTS needs the ffmpeg program (for example: brew install ffmpeg)."
        case .ffmpegFailed(let status, let message): "ffmpeg failed with status \(status): \(message)"
        case .unexpectedDecode(let detail): "The DTS decode is not as Silverside expects: \(detail)."
        case .lossyStream(let format):
            "The disc's tracks hold a DTS stream, which \(format.name) would turn into noise. Encode it in a lossless"
                + " format, or decode the DTS (with ffmpeg)."
        case .noSurround(let format):
            "\(format.name) files cannot hold surround sound here. Decode DTS into FLAC, Apple Lossless, AAC, or AIFF."
        }
    }
}

extension DTSDecoder {
    /// The layout of the track's stream, such as "5.1", from its first frame.
    public func layoutName(of samples: [UInt32]) throws -> String {
        try samples.withUnsafeBytes { bytes in
            guard let frames = DTSStream.frames(in: bytes) else { throw DTSError.unexpectedDecode("no DTS frames") }
            let start = frames.starts[0]
            let frame = Data(UnsafeRawBufferPointer(rebasing: bytes[start..<(start + frames.spacing)]))
            return try FFmpeg.decodeDTS(frame, ffmpeg: ffmpeg).layoutName
        }
    }
}

extension DiscEncoder {
    /// What an encoding of a DTS-CD wrote: the album, and for `DTSChoice.decode`, the decoded
    /// copy beside it.
    public struct DTSEncoding: Sendable {
        public var files: [URL]
        public var encoding: RipReport.Encoding?
        public var copyFiles: [URL] = []
        public var copyEncoding: RipReport.Encoding?
    }

    /// The format of a DTS decode: the library's, if it holds surround sound; else AAC in place
    /// of MP3, and FLAC in place of WAV.
    public static func surroundFormat(for format: AudioFormat) -> AudioFormat {
        AudioEncoder.holdsSurround(format) ? format : format == .mp3 ? .aac : .flac
    }

    /// Encodes the disc as `choice` says for its DTS stream (`ask` keeps it). A disc without
    /// one is encoded as it is. Without ffmpeg, the stream is kept. A lossy format cannot keep
    /// the stream, so there `decode` writes the decoded album only. `copySuffix` ends the
    /// decoded copy's title: " (DTS 5.1)" for 5.1, if not given.
    public func encodeWithRecord(
        _ disc: RippedDisc, into library: URL, dts choice: DTSChoice, copySuffix: String? = nil
    ) throws -> DTSEncoding {
        let tracks = try dtsTracks(of: disc)
        guard !tracks.isEmpty, choice == .decode || choice == .decodeOnly else {
            let (files, encoding) = try encodeWithRecord(disc, into: library)
            return DTSEncoding(files: files, encoding: encoding)
        }
        guard let program = ffmpeg ?? FFmpeg.program() else {
            log(
                "DTS: ffmpeg is not installed, so the files keep the stream. Install it (brew install ffmpeg) to decode it."
            )
            let (files, encoding) = try encodeWithRecord(disc, into: library)
            return DTSEncoding(files: files, encoding: encoding)
        }
        var decoder = self
        decoder.ffmpeg = program
        decoder.decodesDTS = true
        decoder.format = Self.surroundFormat(for: format)
        if decoder.format != format {
            log("DTS: \(format.name) files cannot hold surround sound, so the decode is in \(decoder.format.name).")
        }
        if choice == .decodeOnly || !format.isLossless {
            if choice == .decode {
                log("DTS: \(format.name) would turn the stream into noise, so the album is the decode alone.")
            }
            let (files, encoding) = try decoder.encodeWithRecord(disc, into: library)
            return DTSEncoding(files: files, encoding: encoding)
        }
        let (files, encoding) = try encodeWithRecord(disc, into: library)
        let layout = try disc.tracks.first { tracks.contains($0.number) }.map {
            try DTSDecoder(ffmpeg: program).layoutName(of: disc.audio(of: $0))
        }
        decoder.albumSuffix = copySuffix ?? " (DTS \(layout ?? "surround"))"
        decoder.images = nil
        log("DTS: the decoded copy, as \(disc.release?.title ?? "the album")\(decoder.albumSuffix!).")
        let (copyFiles, copyEncoding) = try decoder.encodeWithRecord(disc, into: library)
        return DTSEncoding(files: files, encoding: encoding, copyFiles: copyFiles, copyEncoding: copyEncoding)
    }
}

extension RipReport {
    /// What the DTS stream means for this rip, for people. Nil without one, and in older reports.
    public var dtsText: String? {
        let streams = tracks.filter { $0.dts == true }.map(\.number)
        guard !streams.isEmpty else { return nil }
        let which =
            streams.count == tracks.count
            ? "every track holds"
            : streams.count == 1 ? "track \(streams[0]) holds" : "tracks \(Self.list(streams)) hold"
        let files =
            encoding.map { encoding in
                encoding.dtsDecoded.map { " The files hold its decode, in \($0)." }
                    ?? " The files keep the stream as the disc has it."
            } ?? ""
        return "DTS: \(which) a DTS stream, surround sound for a DTS decoder; other players play it as static."
            + files
    }
}
