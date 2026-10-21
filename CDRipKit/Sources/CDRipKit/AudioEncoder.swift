import AudioToolbox
import Foundation

/// The output formats. FLAC, ALAC, AAC, and AIFF use Apple's encoders (AudioToolbox);
/// WAV uses `WAVFile`; MP3 uses the external `lame` program (see `MP3Encoder`).
public enum AudioFormat: String, CaseIterable, Codable, Sendable {
    case flac, alac, aac, aiff, wav, mp3

    public var fileExtension: String {
        switch self {
        case .flac: "flac"
        case .alac, .aac: "m4a"
        case .aiff: "aiff"
        case .wav: "wav"
        case .mp3: "mp3"
        }
    }

    /// True if the format keeps every sample, so a decoded file must equal the rip.
    public var isLossless: Bool { self != .aac && self != .mp3 }
}

public enum AudioEncoderError: Error, Equatable, CustomStringConvertible {
    case audioToolbox(operation: String, status: Int32)
    case notThroughAudioToolbox(AudioFormat)

    public var description: String {
        switch self {
        case .audioToolbox(let operation, let status):
            let code = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian) { bytes in
                bytes.allSatisfy { (0x20...0x7E).contains($0) } ? " ('\(String(decoding: bytes, as: UTF8.self))')" : ""
            }
            return "\(operation) failed with status \(status)\(code)"
        case .notThroughAudioToolbox(let format):
            return "\(format.rawValue) is not written through AudioToolbox"
        }
    }
}

/// Encodes ripped audio (16-bit stereo, 44.1 kHz) with AudioToolbox, and decodes files
/// again, so an encoded file can be checked against the rip.
public enum AudioEncoder {
    /// The bit rate for AAC, in bits per second.
    public static let defaultAACBitRate = 256_000

    /// The rip's PCM, as AudioToolbox takes it: interleaved, signed, 16-bit, little-endian.
    static let clientFormat = AudioStreamBasicDescription(
        mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
        mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)

    /// Writes `samples` (CDRip samples: one stereo frame each) to `url` in `format`. WAV
    /// and MP3 have their own writers.
    public static func encode(
        _ samples: [UInt32], format: AudioFormat, to url: URL, aacBitRate: Int = defaultAACBitRate
    ) throws {
        var destination = AudioStreamBasicDescription()
        let fileType: AudioFileTypeID
        destination.mSampleRate = 44_100
        destination.mChannelsPerFrame = 2
        switch format {
        case .flac:
            destination.mFormatID = kAudioFormatFLAC
            destination.mFormatFlags = kAppleLosslessFormatFlag_16BitSourceData
            fileType = kAudioFileFLACType
        case .alac:
            destination.mFormatID = kAudioFormatAppleLossless
            destination.mFormatFlags = kAppleLosslessFormatFlag_16BitSourceData
            fileType = kAudioFileM4AType
        case .aac:
            destination.mFormatID = kAudioFormatMPEG4AAC
            fileType = kAudioFileM4AType
        case .aiff:
            destination = clientFormat
            destination.mFormatFlags =
                kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsBigEndian
            fileType = kAudioFileAIFFType
        case .wav, .mp3:
            throw AudioEncoderError.notThroughAudioToolbox(format)
        }
        if destination.mFormatID != kAudioFormatLinearPCM {
            // The encoder fills in the packet sizes.
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(
                "AudioFormatGetProperty(FormatInfo)",
                AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &destination))
        }

        var file: ExtAudioFileRef?
        try check(
            "ExtAudioFileCreateWithURL",
            ExtAudioFileCreateWithURL(
                url as CFURL, fileType, &destination, nil, AudioFileFlags.eraseFile.rawValue, &file))
        guard let file else { throw AudioEncoderError.audioToolbox(operation: "ExtAudioFileCreateWithURL", status: -1) }
        var closed = false
        defer { if !closed { ExtAudioFileDispose(file) } }

        var client = clientFormat
        try check(
            "ExtAudioFileSetProperty(ClientDataFormat)",
            ExtAudioFileSetProperty(
                file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                &client))
        if format == .aac {
            try setBitRate(aacBitRate, of: file)
        }

        // Write in parts of 1 second.
        let chunk = 44_100
        try samples.withUnsafeBufferPointer { buffer in
            var start = 0
            while start < buffer.count {
                let count = min(chunk, buffer.count - start)
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2, mDataByteSize: UInt32(count * 4),
                        mData: UnsafeMutableRawPointer(mutating: buffer.baseAddress! + start)))
                try check("ExtAudioFileWrite", ExtAudioFileWrite(file, UInt32(count), &list))
                start += count
            }
        }
        closed = true
        try check("ExtAudioFileDispose", ExtAudioFileDispose(file))
    }

    /// Reads a file that AudioToolbox can decode (FLAC, ALAC, AAC, AIFF, WAV, MP3) as CDRip samples.
    public static func decode(_ url: URL) throws -> [UInt32] {
        var file: ExtAudioFileRef?
        try check("ExtAudioFileOpenURL", ExtAudioFileOpenURL(url as CFURL, &file))
        guard let file else { throw AudioEncoderError.audioToolbox(operation: "ExtAudioFileOpenURL", status: -1) }
        defer { ExtAudioFileDispose(file) }
        var client = clientFormat
        try check(
            "ExtAudioFileSetProperty(ClientDataFormat)",
            ExtAudioFileSetProperty(
                file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                &client))
        var samples = [UInt32]()
        var part = [UInt32](repeating: 0, count: 44_100)
        while true {
            var frames = UInt32(part.count)
            let status = part.withUnsafeMutableBytes { bytes -> OSStatus in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                return ExtAudioFileRead(file, &frames, &list)
            }
            try check("ExtAudioFileRead", status)
            if frames == 0 { break }
            samples += part[0..<Int(frames)]
        }
        return samples
    }

    private static func setBitRate(_ bitRate: Int, of file: ExtAudioFileRef) throws {
        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        try check(
            "ExtAudioFileGetProperty(AudioConverter)",
            ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter))
        guard let converter else { return }
        var rate = UInt32(bitRate)
        try check(
            "AudioConverterSetProperty(EncodeBitRate)",
            AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate)
        )
        // The converter changed: a null configuration makes the file read its settings again.
        var none: UnsafeRawPointer?
        try check(
            "ExtAudioFileSetProperty(ConverterConfig)",
            ExtAudioFileSetProperty(
                file, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<UnsafeRawPointer?>.size), &none))
    }

    private static func check(_ operation: String, _ status: OSStatus) throws {
        guard status == noErr else { throw AudioEncoderError.audioToolbox(operation: operation, status: status) }
    }
}
