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

/// Audio of more channels than two, as a DTS decode gives it: interleaved 32-bit values (as in
/// `TrackPCM.wide`) in WAVE's channel order, which `channelMask` names with WAVE's bits.
/// Core Audio's channel bitmap gives the bits the same meanings.
public struct SurroundPCM: Equatable, Sendable {
    public var values: [Int32]
    public var channels: Int
    public var channelMask: UInt32
    /// The bits that the values use: 20 or 24 (FLAC and Apple Lossless keep these).
    public var bits: Int

    public init(values: [Int32], channels: Int, channelMask: UInt32, bits: Int = 24) {
        self.values = values
        self.channels = channels
        self.channelMask = channelMask
        self.bits = bits
    }

    public var frameCount: Int { values.count / channels }

    /// The usual channels for a count, as FLAC orders them: 5.1 for 6.
    static func standardMask(channels: Int) -> UInt32 {
        switch channels {
        case 1: 0x4
        case 2: 0x3
        case 3: 0x7
        case 4: 0x33
        case 5: 0x37
        case 6: 0x3F
        case 7: 0x70F
        case 8: 0x63F
        default: 0
        }
    }

    /// WAVE's bit for the low-frequency effects channel.
    static let lfeBit: UInt32 = 0x8

    /// The layout's name, as people know it: "5.1", "5.0", or "2.0".
    public var layoutName: String {
        let lfe = channelMask & Self.lfeBit != 0 ? 1 : 0
        return "\(channels - lfe).\(lfe)"
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

    /// The formats that surround audio can be written in.
    public static func holdsSurround(_ format: AudioFormat) -> Bool {
        switch format {
        case .flac, .alac, .aac, .aiff: true
        case .wav, .mp3: false
        }
    }

    /// Writes surround audio to `url` in `format` (FLAC, Apple Lossless, AAC, or AIFF): the
    /// lossless formats keep the audio's `bits`, AIFF 24. The file names its channels, so
    /// players route them.
    public static func encode(
        _ audio: SurroundPCM, format: AudioFormat, to url: URL, aac: AACOptions = AACOptions()
    ) throws {
        guard holdsSurround(format) else { throw DTSError.noSurround(format) }
        // The channels in the layout's order, so that AudioToolbox converts none (`SurroundLayout`).
        let layout = try SurroundLayout.of(mask: audio.channelMask, format: format)
        let values = layout?.arrange(audio) ?? audio.values
        let channels = UInt32(layout?.channels ?? audio.channels)
        var destination = AudioStreamBasicDescription()
        destination.mSampleRate = 44_100
        destination.mChannelsPerFrame = channels
        let bitsFlag =
            audio.bits == 20 ? kAppleLosslessFormatFlag_20BitSourceData : kAppleLosslessFormatFlag_24BitSourceData
        var fileLayout = AudioChannelLayout()
        if let layout {
            fileLayout.mChannelLayoutTag = layout.tag
        } else {
            fileLayout = Self.layout(bitmap: audio.channelMask)
        }
        let fileType: AudioFileTypeID
        switch format {
        case .flac:
            destination.mFormatID = kAudioFormatFLAC
            destination.mFormatFlags = bitsFlag
            fileType = kAudioFileFLACType
        case .alac:
            destination.mFormatID = kAudioFormatAppleLossless
            destination.mFormatFlags = bitsFlag
            fileType = kAudioFileM4AType
        case .aac:
            destination.mFormatID = kAudioFormatMPEG4AAC
            fileType = kAudioFileM4AType
        default:
            destination.mFormatID = kAudioFormatLinearPCM
            destination.mFormatFlags =
                kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsBigEndian
            destination.mBitsPerChannel = 24
            destination.mBytesPerFrame = 3 * channels
            destination.mBytesPerPacket = 3 * channels
            destination.mFramesPerPacket = 1
            fileType = kAudioFileAIFFType
        }
        if destination.mFormatID != kAudioFormatLinearPCM {
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(
                "AudioFormatGetProperty(FormatInfo)",
                AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &destination))
        }
        var file: ExtAudioFileRef?
        try check(
            "ExtAudioFileCreateWithURL",
            ExtAudioFileCreateWithURL(
                url as CFURL, fileType, &destination, &fileLayout, AudioFileFlags.eraseFile.rawValue, &file))
        guard let file else { throw AudioEncoderError.audioToolbox(operation: "ExtAudioFileCreateWithURL", status: -1) }
        var closed = false
        defer { if !closed { ExtAudioFileDispose(file) } }
        try setClient(of: file, channels: Int(channels))
        if format == .aac { try configure(aac, of: file) }
        let bytesPerFrame = 4 * Int(channels)
        try values.withUnsafeBytes { bytes in
            let frames = bytes.count / bytesPerFrame
            var start = 0
            while start < frames {
                let count = min(44_100, frames - start)
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: channels, mDataByteSize: UInt32(count * bytesPerFrame),
                        mData: UnsafeMutableRawPointer(mutating: bytes.baseAddress! + start * bytesPerFrame)))
                try check("ExtAudioFileWrite", ExtAudioFileWrite(file, UInt32(count), &list))
                start += count
            }
        }
        closed = true
        try check("ExtAudioFileDispose", ExtAudioFileDispose(file))
    }

    /// Reads a file of any number of channels as 32-bit values, in WAVE's channel order.
    public static func decodeSurround(_ url: URL) throws -> SurroundPCM {
        let file = try readChannels(url)
        if let bitmap = file.bitmap, SurroundLayout.speakers(of: bitmap).count == file.channels {
            return SurroundPCM(values: file.values, channels: file.channels, channelMask: bitmap)
        }
        guard let labels = file.labels, let speakers = SurroundLayout.speakers(of: labels) else {
            return SurroundPCM(
                values: file.values, channels: file.channels,
                channelMask: SurroundPCM.standardMask(channels: file.channels))
        }
        // WAVE's order is the speakers' bits from the lowest.
        let order = speakers.indices.sorted { speakers[$0] < speakers[$1] }
        let source = SurroundPCM(values: file.values, channels: file.channels, channelMask: 0)
        let layout = SurroundLayout(tag: 0, sources: order)
        return SurroundPCM(
            values: layout.arrange(source), channels: file.channels, channelMask: speakers.reduce(0, |))
    }

    /// Reads a file written from audio with `mask`'s speakers: each speaker's channel, in the
    /// audio's own order, as the encoder placed it (`SurroundLayout`). Nil if the file has no
    /// place for one of them.
    static func decodeSurround(_ url: URL, as mask: UInt32) throws -> SurroundPCM? {
        let file = try readChannels(url)
        let speakers = SurroundLayout.speakers(of: mask)
        if file.bitmap == mask || (file.labels == nil && file.channels == speakers.count) {
            return SurroundPCM(values: file.values, channels: file.channels, channelMask: mask)
        }
        guard let labels = file.labels, let places = SurroundLayout.assign(speakers, to: labels) else { return nil }
        // The file channel of each speaker, in the speakers' order.
        let order = speakers.indices.map { speaker in places.firstIndex(of: speaker)! }
        let source = SurroundPCM(values: file.values, channels: file.channels, channelMask: 0)
        let picked = SurroundLayout(tag: 0, sources: order).arrange(source)
        return SurroundPCM(values: picked, channels: speakers.count, channelMask: mask)
    }

    /// A file's values in its own channel order, and the speakers its layout names: a bitmap,
    /// or Core Audio's labels.
    private static func readChannels(_ url: URL) throws -> (
        values: [Int32], channels: Int, bitmap: UInt32?, labels: [AudioChannelLabel]?
    ) {
        var file: ExtAudioFileRef?
        try check("ExtAudioFileOpenURL", ExtAudioFileOpenURL(url as CFURL, &file))
        guard let file else { throw AudioEncoderError.audioToolbox(operation: "ExtAudioFileOpenURL", status: -1) }
        defer { ExtAudioFileDispose(file) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            "ExtAudioFileGetProperty(FileDataFormat)",
            ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format))
        let channels = Int(format.mChannelsPerFrame)
        let (bitmap, labels) = fileSpeakers(of: file)
        try setClient(of: file, channels: channels)
        var values = [Int32]()
        var part = [Int32](repeating: 0, count: 44_100 * channels)
        while true {
            var frames = UInt32(44_100)
            let status = part.withUnsafeMutableBytes { bytes -> OSStatus in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels), mDataByteSize: UInt32(bytes.count),
                        mData: bytes.baseAddress))
                return ExtAudioFileRead(file, &frames, &list)
            }
            try check("ExtAudioFileRead", status)
            if frames == 0 { break }
            values += part[0..<(Int(frames) * channels)]
        }
        return (values, channels, bitmap, labels.flatMap { $0.count == channels ? $0 : nil })
    }

    private static func layout(bitmap: UInt32) -> AudioChannelLayout {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap
        layout.mChannelBitmap = AudioChannelBitmap(rawValue: bitmap)
        return layout
    }

    /// The speakers the file's layout names: a bitmap, or the labels of its channels.
    private static func fileSpeakers(of file: ExtAudioFileRef) -> (bitmap: UInt32?, labels: [AudioChannelLabel]?) {
        var size: UInt32 = 0
        // A layout with no channel descriptions is shorter than `AudioChannelLayout`, which has room for one.
        let header = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        guard ExtAudioFileGetPropertyInfo(file, kExtAudioFileProperty_FileChannelLayout, &size, nil) == noErr,
            size >= header
        else { return (nil, nil) }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: max(Int(size), MemoryLayout<AudioChannelLayout>.size), alignment: 8)
        buffer.initializeMemory(
            as: UInt8.self, repeating: 0, count: max(Int(size), MemoryLayout<AudioChannelLayout>.size))
        defer { buffer.deallocate() }
        guard ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileChannelLayout, &size, buffer) == noErr else {
            return (nil, nil)
        }
        let layout = buffer.assumingMemoryBound(to: AudioChannelLayout.self)
        switch layout.pointee.mChannelLayoutTag {
        case kAudioChannelLayoutTag_UseChannelBitmap: return (layout.pointee.mChannelBitmap.rawValue, nil)
        case kAudioChannelLayoutTag_UseChannelDescriptions: return (nil, SurroundLayout.labels(ofDescriptions: layout))
        case let tag: return (nil, SurroundLayout.labels(of: tag))
        }
    }

    /// Sets the file's client format to interleaved 32-bit values in the file's own channel
    /// order: no client layout, so AudioToolbox moves no channel.
    private static func setClient(of file: ExtAudioFileRef, channels: Int) throws {
        var client = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        try check(
            "ExtAudioFileSetProperty(ClientDataFormat)",
            ExtAudioFileSetProperty(
                file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                &client))
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
