import AudioToolbox
import CryptoKit
import Darwin
import Foundation

/// Integer PCM in WAVE speaker order. Samples are left-aligned in Int32 storage;
/// `bits` records their meaningful precision, independently of the storage width.
public struct PCMFormat: Codable, Equatable, Sendable {
    public let sampleRate: Double
    public let channels: Int
    public let channelMask: UInt32
    public let bits: Int

    public init(sampleRate: Double, channels: Int, channelMask: UInt32, bits: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.channelMask = channelMask
        self.bits = bits
    }

    func validate() throws {
        guard sampleRate.isFinite, sampleRate >= 1, sampleRate <= 384_000,
            sampleRate.rounded() == sampleRate, (1...8).contains(channels),
            channelMask.nonzeroBitCount == channels, [16, 20, 24].contains(bits)
        else {
            throw AudioEncoderError.invalidPCM("Unsupported PCM rate, precision, or speaker layout.")
        }
    }

    func validate(values: [Int32]) throws {
        guard values.count % channels == 0 else { throw AudioEncoderError.invalidPCM("Incomplete PCM frame.") }
        let unused = UInt32.max >> bits
        guard values.allSatisfy({ UInt32(bitPattern: $0) & unused == 0 }) else {
            throw AudioEncoderError.invalidPCM("PCM values contain information below their declared precision.")
        }
    }
}

/// A bounded, native-rate reader for integer PCM, FLAC and ALAC files. Each read
/// returns canonical WAVE channel order, without asking AudioToolbox to remix.
/// Use on one thread at a time, like FileHandle.
public final class PCMFileReader {
    public let format: PCMFormat
    public let frameCount: Int64
    private let file: ExtAudioFileRef
    private let order: [Int]

    public init(_ url: URL) throws {
        var opened: ExtAudioFileRef?
        try AudioEncoder.check("ExtAudioFileOpenURL", ExtAudioFileOpenURL(url as CFURL, &opened))
        guard let opened else { throw AudioEncoderError.invalidPCM("Cannot open PCM source.") }
        do {
            var source = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try AudioEncoder.check(
                "FileDataFormat", ExtAudioFileGetProperty(opened, kExtAudioFileProperty_FileDataFormat, &size, &source))
            guard [kAudioFormatLinearPCM, kAudioFormatFLAC, kAudioFormatAppleLossless].contains(source.mFormatID),
                source.mFormatID != kAudioFormatLinearPCM || source.mFormatFlags & kAudioFormatFlagIsFloat == 0
            else {
                throw AudioEncoderError.invalidPCM("Native lossless conversion requires integer PCM, FLAC, or ALAC.")
            }
            let channels = Int(source.mChannelsPerFrame)
            let (bitmap, labels) = AudioEncoder.fileSpeakers(of: opened)
            let speakers: [UInt32]
            if let bitmap, bitmap.nonzeroBitCount == channels {
                speakers = SurroundLayout.speakers(of: bitmap)
            } else if let labels, labels.count == channels, let found = SurroundLayout.speakers(of: labels) {
                speakers = found
            } else if channels <= 2 || source.mFormatID == kAudioFormatFLAC {
                speakers = SurroundLayout.speakers(of: SurroundPCM.standardMask(channels: channels))
            } else {
                throw AudioEncoderError.invalidPCM("The source does not identify its speakers.")
            }
            let pcm = PCMFormat(
                sampleRate: source.mSampleRate, channels: channels,
                channelMask: speakers.reduce(0, |), bits: AudioEncoder.sourceBits(source))
            try pcm.validate()
            guard speakers.count == channels else {
                throw AudioEncoderError.invalidPCM("Invalid source speaker layout.")
            }
            format = pcm
            order = speakers.indices.sorted { speakers[$0] < speakers[$1] }
            var count: Int64 = 0
            size = UInt32(MemoryLayout<Int64>.size)
            try AudioEncoder.check(
                "FileLengthFrames",
                ExtAudioFileGetProperty(opened, kExtAudioFileProperty_FileLengthFrames, &size, &count))
            guard count >= 0 else { throw AudioEncoderError.invalidPCM("Invalid source frame count.") }
            frameCount = count
            try AudioEncoder.setClient(of: opened, channels: channels, sampleRate: pcm.sampleRate)
            file = opened
        } catch {
            ExtAudioFileDispose(opened)
            throw error
        }
    }

    deinit { ExtAudioFileDispose(file) }

    public func read(maxFrames: Int = 16_384) throws -> [Int32]? {
        guard (1...65_536).contains(maxFrames) else {
            throw AudioEncoderError.invalidPCM("PCM reads must request 1...65536 frames.")
        }
        var values = [Int32](repeating: 0, count: maxFrames * format.channels)
        var frames = UInt32(maxFrames)
        let status = values.withUnsafeMutableBytes { bytes in
            var buffer = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(format.channels), mDataByteSize: UInt32(bytes.count),
                    mData: bytes.baseAddress))
            return ExtAudioFileRead(file, &frames, &buffer)
        }
        try AudioEncoder.check("ExtAudioFileRead", status)
        guard frames > 0 else { return nil }
        values.removeLast(values.count - Int(frames) * format.channels)
        if order == Array(0..<format.channels) { return values }
        let source = SurroundPCM(
            values: values, channels: format.channels, channelMask: format.channelMask,
            bits: format.bits, sampleRate: format.sampleRate)
        return SurroundLayout(tag: 0, sources: order.map { Optional($0) }).arrange(source)
    }
}

extension AudioEncoder {
    /// Compressed lossless ASBDs may put precision in their source-data flags.
    static func sourceBits(_ source: AudioStreamBasicDescription) -> Int {
        if source.mBitsPerChannel > 0 { return Int(source.mBitsPerChannel) }
        if source.mFormatID == kAudioFormatFLAC || source.mFormatID == kAudioFormatAppleLossless {
            switch source.mFormatFlags {
            case kAppleLosslessFormatFlag_16BitSourceData: return 16
            case kAppleLosslessFormatFlag_20BitSourceData: return 20
            case kAppleLosslessFormatFlag_24BitSourceData: return 24
            case kAppleLosslessFormatFlag_32BitSourceData: return 32
            default: return 0
            }
        }
        return 24  // Legacy lossy decode exposes 32-bit samples, with no source bit depth.
    }

    public struct PCMConversion: Codable, Sendable {
        public let pcm: PCMFormat
        public let frames: Int64
        /// SHA-256 of canonical interleaved, left-aligned signed 32-bit little-endian PCM.
        public let pcmSHA256: String
    }

    /// Streaming file conversion for the DVD library workflow. Requires a new output,
    /// preserves the source, and publishes only after format, length and PCM checks.
    /// Metadata is deliberately left to the tagging stage.
    public static func transcodeLossless(
        _ source: URL, format: AudioFormat, to output: URL, stop: StopToken = StopToken()
    ) throws -> PCMConversion {
        guard format == .flac || format == .alac else {
            throw AudioEncoderError.invalidPCM("Native lossless conversion currently writes FLAC or ALAC.")
        }
        try stop.check()
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw AudioEncoderError.invalidPCM("The conversion output must be a new file.")
        }
        let reader = try PCMFileReader(source)
        let staging = output.deletingLastPathComponent().appendingPathComponent(
            ".silverside-pcm-\(UUID()).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: staging) }
        var sourceHash = SHA256()
        var frames: Int64 = 0
        try encode(pcm: reader.format, format: format, to: staging) {
            try stop.check()
            guard let values = try reader.read() else { return nil }
            values.withUnsafeBytes { sourceHash.update(bufferPointer: $0) }
            frames += Int64(values.count / reader.format.channels)
            return values
        }
        guard frames == reader.frameCount else {
            throw AudioEncoderError.invalidPCM("Source length differs from its declared frame count.")
        }
        let decoded = try PCMFileReader(staging)
        guard decoded.format == reader.format, decoded.frameCount == frames else {
            throw AudioEncoderError.invalidPCM(
                "Encoded format \(decoded.format), \(decoded.frameCount) frames differs from source \(reader.format), \(frames) frames."
            )
        }
        var outputHash = SHA256()
        var decodedFrames: Int64 = 0
        while let values = try decoded.read() {
            try stop.check()
            values.withUnsafeBytes { outputHash.update(bufferPointer: $0) }
            decodedFrames += Int64(values.count / decoded.format.channels)
        }
        let digest = sourceHash.finalize()
        guard decodedFrames == frames, outputHash.finalize() == digest else {
            throw AudioEncoderError.invalidPCM("Encoded PCM differs from the source.")
        }
        try stop.check()
        // An exclusive same-directory rename also refuses symlinks, hard-link
        // aliases and destinations created during conversion, without requiring
        // a filesystem that supports hard links.
        guard renamex_np(staging.path, output.path, UInt32(RENAME_EXCL)) == 0 else {
            throw AudioEncoderError.invalidPCM("Cannot publish new output: \(String(cString: strerror(errno))).")
        }
        return PCMConversion(
            pcm: reader.format, frames: frames,
            pcmSHA256: digest.map { String(format: "%02x", $0) }.joined())
    }
}
