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

    /// The bits of audio wider than the disc's 16 (an HDCD decode, or de-emphasized audio) in
    /// this format: 20 for FLAC and Apple Lossless, HDCD's own resolution, which puts the
    /// rounding error near -120 dBFS, under the 16-bit source's own noise (the bits below it
    /// would cost a third more space in Apple Lossless); 24 for AIFF and WAV, which store 20
    /// bits in three bytes anyway, and for the lossy encoders' input.
    public var wideBits: Int {
        switch self {
        case .flac, .alac: 20
        case .aiff, .wav, .aac, .mp3: 24
        }
    }

    /// True if decoding HDCD is the advice for this format: the lossy formats lose the codes,
    /// so their files can never be decoded later, and 20-bit FLAC and Apple Lossless are not
    /// much larger. 24-bit AIFF and WAV files are half again as large, so they keep the disc as pressed.
    public var recommendsHDCDDecode: Bool {
        switch self {
        case .flac, .alac, .aac, .mp3: true
        case .aiff, .wav: false
        }
    }

    /// The format's name, for people to read.
    public var name: String {
        switch self {
        case .flac: "FLAC"
        case .alac: "Apple Lossless"
        case .aac: "AAC"
        case .aiff: "AIFF"
        case .wav: "WAV"
        case .mp3: "MP3"
        }
    }
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

/// A track's audio, ready to encode: the rip's 16-bit samples, or the wider samples of an
/// HDCD decode.
public enum TrackPCM: Equatable, Sendable {
    /// Silverside samples: one stereo frame each, the left value in the low half.
    case cd([UInt32])
    /// Interleaved values (left, right, ...), each a sample in the high 24 bits of an `Int32`,
    /// its low 8 bits zero: 32-bit PCM, as AudioToolbox and lame take it. FLAC and Apple
    /// Lossless keep the high 20 bits (`AudioFormat.wideBits`), so for those the low 12 must be zero.
    case wide([Int32])

    public var frameCount: Int {
        switch self {
        case .cd(let samples): samples.count
        case .wide(let values): values.count / 2
        }
    }

    /// The bits of each sample: 16, or 24 (20 of them in FLAC and Apple Lossless).
    public var bitsPerSample: Int {
        switch self {
        case .cd: 16
        case .wide: 24
        }
    }
}

/// Encodes ripped audio (stereo, 44.1 kHz, 16, 20, or 24 bits) with AudioToolbox, and decodes
/// files again, so an encoded file can be checked against the rip.
public enum AudioEncoder {
    /// The rip's PCM, as AudioToolbox takes it: interleaved, signed, 16-bit, little-endian.
    static let clientFormat = AudioStreamBasicDescription(
        mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
        mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)

    /// Wide audio as AudioToolbox takes it: 32-bit values (`TrackPCM.wide`).
    static let wideClientFormat = AudioStreamBasicDescription(
        mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
        mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)

    /// Writes `samples` (Silverside samples: one stereo frame each) to `url` in `format`. WAV
    /// and MP3 have their own writers.
    public static func encode(
        _ samples: [UInt32], format: AudioFormat, to url: URL, aac: AACOptions = AACOptions()
    ) throws {
        try encode(.cd(samples), format: format, to: url, aac: aac)
    }

    /// Writes `pcm` to `url` in `format`: a lossless format keeps its 16 bits, or for wide
    /// audio the format's `wideBits`. WAV and MP3 have their own writers.
    public static func encode(
        _ pcm: TrackPCM, format: AudioFormat, to url: URL, aac: AACOptions = AACOptions()
    ) throws {
        let file = try create(url, format: format, wide: pcm.bitsPerSample == 24, aac: aac)
        var closed = false
        defer { if !closed { ExtAudioFileDispose(file) } }
        switch pcm {
        case .cd(let samples): try samples.withUnsafeBytes { try write($0, bytesPerFrame: 4, to: file) }
        case .wide(let values): try values.withUnsafeBytes { try write($0, bytesPerFrame: 8, to: file) }
        }
        closed = true
        try check("ExtAudioFileDispose", ExtAudioFileDispose(file))
    }

    /// Writes 16-bit audio to `url` in `format`, part by part: `next` gives each part, and nil
    /// at the end. For a whole disc, which is too large to hold at once.
    public static func encode(
        format: AudioFormat, to url: URL, aac: AACOptions = AACOptions(), parts next: () throws -> [UInt32]?
    ) throws {
        let file = try create(url, format: format, wide: false, aac: aac)
        var closed = false
        defer { if !closed { ExtAudioFileDispose(file) } }
        while let samples = try next() {
            try samples.withUnsafeBytes { try write($0, bytesPerFrame: 4, to: file) }
        }
        closed = true
        try check("ExtAudioFileDispose", ExtAudioFileDispose(file))
    }

    /// A new file at `url` in `format`, which takes 16-bit audio, or 32-bit if `wide`.
    private static func create(_ url: URL, format: AudioFormat, wide: Bool, aac: AACOptions) throws -> ExtAudioFileRef {
        let wideFlag =
            format.wideBits == 20 ? kAppleLosslessFormatFlag_20BitSourceData : kAppleLosslessFormatFlag_24BitSourceData
        var destination = AudioStreamBasicDescription()
        let fileType: AudioFileTypeID
        destination.mSampleRate = 44_100
        destination.mChannelsPerFrame = 2
        switch format {
        case .flac:
            destination.mFormatID = kAudioFormatFLAC
            destination.mFormatFlags = wide ? wideFlag : kAppleLosslessFormatFlag_16BitSourceData
            fileType = kAudioFileFLACType
        case .alac:
            destination.mFormatID = kAudioFormatAppleLossless
            destination.mFormatFlags = wide ? wideFlag : kAppleLosslessFormatFlag_16BitSourceData
            fileType = kAudioFileM4AType
        case .aac:
            destination.mFormatID = kAudioFormatMPEG4AAC
            fileType = kAudioFileM4AType
        case .aiff:
            destination = clientFormat
            destination.mFormatFlags =
                kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsBigEndian
            if wide {
                destination.mBitsPerChannel = 24
                destination.mBytesPerFrame = 6
                destination.mBytesPerPacket = 6
            }
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
        do {
            var client = wide ? wideClientFormat : clientFormat
            try check(
                "ExtAudioFileSetProperty(ClientDataFormat)",
                ExtAudioFileSetProperty(
                    file, kExtAudioFileProperty_ClientDataFormat,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client))
            if format == .aac {
                try configure(aac, of: file)
            }
        } catch {
            ExtAudioFileDispose(file)
            throw error
        }
        return file
    }

    /// Writes interleaved frames to the file, in parts of 1 second.
    private static func write(_ bytes: UnsafeRawBufferPointer, bytesPerFrame: Int, to file: ExtAudioFileRef) throws {
        let frames = bytes.count / bytesPerFrame
        var start = 0
        while start < frames {
            let count = min(44_100, frames - start)
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(count * bytesPerFrame),
                    mData: UnsafeMutableRawPointer(mutating: bytes.baseAddress! + start * bytesPerFrame)))
            try check("ExtAudioFileWrite", ExtAudioFileWrite(file, UInt32(count), &list))
            start += count
        }
    }

    /// Reads a file that AudioToolbox can decode (FLAC, ALAC, AAC, AIFF, WAV, MP3) as Silverside samples.
    public static func decode(_ url: URL) throws -> [UInt32] {
        try read(url, client: clientFormat, as: UInt32.self)
    }

    /// Reads a file as 32-bit values (`TrackPCM.wide`), so a 20-bit or 24-bit file keeps its bits.
    public static func decodeWide(_ url: URL) throws -> [Int32] {
        try read(url, client: wideClientFormat, as: Int32.self)
    }

    /// The file's audio in the client format: one `T` a frame (16-bit) or one a channel (32-bit).
    private static func read<T: FixedWidthInteger>(
        _ url: URL, client format: AudioStreamBasicDescription, as: T.Type
    ) throws -> [T] {
        var file: ExtAudioFileRef?
        try check("ExtAudioFileOpenURL", ExtAudioFileOpenURL(url as CFURL, &file))
        guard let file else { throw AudioEncoderError.audioToolbox(operation: "ExtAudioFileOpenURL", status: -1) }
        defer { ExtAudioFileDispose(file) }
        var client = format
        try check(
            "ExtAudioFileSetProperty(ClientDataFormat)",
            ExtAudioFileSetProperty(
                file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                &client))
        var samples = [T]()
        try read(file, client: format) { samples += $0 }
        return samples
    }

    /// Reads a file that AudioToolbox can decode as Silverside samples, a second at a time:
    /// `part` gets each second. For a whole disc, which is too large to hold at once.
    public static func decode(_ url: URL, parts part: (ArraySlice<UInt32>) throws -> Void) throws {
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
        try read(file, client: clientFormat, part)
    }

    /// Reads the open file to its end, a second at a time.
    private static func read<T: FixedWidthInteger>(
        _ file: ExtAudioFileRef, client format: AudioStreamBasicDescription, _ body: (ArraySlice<T>) throws -> Void
    ) throws {
        let perFrame = Int(format.mBytesPerFrame) / MemoryLayout<T>.size
        var part = [T](repeating: 0, count: 44_100 * perFrame)
        while true {
            var frames = UInt32(44_100)
            let status = part.withUnsafeMutableBytes { bytes -> OSStatus in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                return ExtAudioFileRead(file, &frames, &list)
            }
            try check("ExtAudioFileRead", status)
            if frames == 0 { break }
            try body(part[0..<(Int(frames) * perFrame)])
        }
    }

    /// Sets the AAC encoder's mode, then its bit rate or its VBR quality.
    private static func configure(_ options: AACOptions, of file: ExtAudioFileRef) throws {
        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        try check(
            "ExtAudioFileGetProperty(AudioConverter)",
            ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter))
        guard let converter else { return }
        let valueSize = UInt32(MemoryLayout<UInt32>.size)
        var mode = options.mode.audioToolboxMode
        try check(
            "AudioConverterSetProperty(BitRateControlMode)",
            AudioConverterSetProperty(converter, kAudioCodecPropertyBitRateControlMode, valueSize, &mode))
        if options.mode == .vbr {
            var quality = UInt32(min(max(options.vbrQuality, 0), 127))
            try check(
                "AudioConverterSetProperty(SoundQualityForVBR)",
                AudioConverterSetProperty(converter, kAudioCodecPropertySoundQualityForVBR, valueSize, &quality))
        } else {
            var rate = UInt32(options.bitRate * 1000)
            try check(
                "AudioConverterSetProperty(EncodeBitRate)",
                AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, valueSize, &rate))
        }
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
