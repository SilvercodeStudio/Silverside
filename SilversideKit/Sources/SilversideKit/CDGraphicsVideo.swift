import AVFoundation
import CoreMedia
import Foundation

/// A video of a CD+G disc: its graphics as a CD+G player draws them (`CDGraphicsScreen`) over
/// its audio, the whole disc in one file with a chapter for each track, named by its title.
/// The audio is Apple Lossless, the rip's audio exactly, or AAC for a smaller file; the
/// picture is H.264 or HEVC, each of the screen's pixels drawn `scale` × `scale`, so that its
/// edges stay sharp. AVFoundation writes it, as a `.m4v` that QuickTime Player, the TV app,
/// VLC, and others play, with the chapters in a text track. (AVFoundation writes no FLAC in a
/// video file.)
public struct CDGraphicsVideo: Sendable {
    /// A track of the video: its title, its `.cdg` file (nil for a track without graphics,
    /// which leaves the screen as the track before left it), and its audio.
    public struct Chapter: Sendable {
        public var title: String
        public var graphics: URL?
        public var sectors: Int
        /// The track's audio, `sectors` × 588 samples, read when the video comes to it.
        public var audio: @Sendable () throws -> [UInt32]

        public init(title: String, graphics: URL?, sectors: Int, audio: @escaping @Sendable () throws -> [UInt32]) {
            self.title = title
            self.graphics = graphics
            self.sectors = sectors
            self.audio = audio
        }
    }

    public enum Codec: String, Sendable, CaseIterable {
        case h264
        case hevc
    }

    /// The video's audio.
    public enum Audio: String, Codable, Sendable, CaseIterable {
        /// Apple Lossless: the rip's audio exactly.
        case appleLossless
        /// AAC at `aacBitRate`: about a quarter of the size.
        case aac

        public var name: String { self == .aac ? "AAC" : "Apple Lossless" }
    }

    /// The AAC's bit rate, in bits a second.
    public static let aacBitRate = 256_000

    /// The video's picture.
    public enum Picture: String, Codable, Sendable, CaseIterable {
        /// As a CD+EG player shows it: the 256 colors where the disc has them, and its CD+G
        /// pictures where it has only those. A CD+G disc's video.
        case extended = "eg"
        /// As a CD+G player shows a CD+EG disc: 16 colors, the CD+EG layer left out.
        case standard = "g"
    }

    /// Which pictures a CD+EG disc's video has: the CD+EG one, the CD+G one, or both, each in
    /// a file of its own. A CD+G disc gets one video either way.
    public enum Pictures: String, Codable, Sendable, CaseIterable {
        case eg
        case g
        case both

        public var pictures: [Picture] {
            switch self {
            case .eg: [.extended]
            case .g: [.standard]
            case .both: [.extended, .standard]
            }
        }
    }

    /// What a rip's video is to be: its audio, and for a CD+EG disc, its pictures.
    public struct Request: Equatable, Sendable {
        public var audio: Audio
        public var pictures: Pictures

        public init(audio: Audio, pictures: Pictures = .eg) {
            self.audio = audio
            self.pictures = pictures
        }
    }

    /// Frames a second: 10 packs each, of the 300 a second that the graphics come in.
    public static let framesPerSecond = 30
    static let packsPerFrame = 10
    /// Samples a second.
    static let sampleRate = CDDA.samplesPerSector * CDDA.sectorsPerSecond

    public var codec = Codec.h264
    public var audio = Audio.appleLossless
    public var picture = Picture.extended
    /// Each screen pixel is drawn this many pixels wide and high: 4 makes 1200 × 864.
    public var scale = 4
    /// The video's title and artist, in its tags: the album's, for the TV app and others.
    public var title: String?
    public var artist: String?

    public init() {}

    public enum VideoError: Error, CustomStringConvertible {
        case noGraphics
        case writer(String)

        public var description: String {
            switch self {
            case .noGraphics: "The rip has no CD+G graphics."
            case .writer(let message): "The video could not be written: \(message)"
            }
        }
    }

    /// The chapters of a ripped disc: its audio tracks, each with its title from the release
    /// (with the user's edits) or "Track N", its `.cdg` file, and its audio. Throws if no
    /// track has graphics.
    public static func chapters(of disc: RippedDisc) throws -> [Chapter] {
        let medium = disc.release?.medium(for: disc.toc)
        // An album's graphics are beside its files, by their names.
        let files =
            disc.isAlbum
            ? (disc.report?.encoding?.graphicsFiles ?? []).map { ($0.track, $0.file) }
            : (disc.report?.tracks ?? []).compactMap { track in track.graphics.map { (track.number, $0.file) } }
        let graphics = Dictionary(files, uniquingKeysWith: { first, _ in first })
        guard !graphics.isEmpty else { throw VideoError.noGraphics }
        return disc.tracks.filter { $0.number > 0 }.compactMap { track in
            guard let toc = disc.toc.track(track.number) else { return nil }
            let title = medium?.tracks.first { $0.position == track.number }?.title ?? "Track \(track.number)"
            return Chapter(
                title: title, graphics: graphics[track.number].map { disc.folder.appending(path: $0) },
                sectors: disc.toc.sectorRange(of: toc).count, audio: { try disc.audio(of: track) })
        }
    }

    /// Writes the video of `chapters` to `url` (a `.m4v`), replacing a file there. `progress`
    /// gets the fraction written.
    public func write(
        _ chapters: [Chapter], to url: URL, stop: StopToken? = nil, progress: (Double) -> Void = { _ in }
    ) throws {
        let fileManager = FileManager.default
        let partial = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).partial")
        try? fileManager.removeItem(at: partial)
        defer { try? fileManager.removeItem(at: partial) }

        // The packs of the whole disc, 24 bytes each, 4 a sector: about 19 MB for 44 minutes.
        var packs = Data()
        for chapter in chapters {
            let count = chapter.sectors * 4 * 24
            var data = try chapter.graphics.map { try Data(contentsOf: $0) } ?? Data()
            if data.count > count { data = data.prefix(count) }
            if data.count < count { data.append(Data(count: count - data.count)) }
            packs.append(data)
        }
        let totalPacks = packs.count / 24
        let totalFrames = (totalPacks + Self.packsPerFrame - 1) / Self.packsPerFrame
        let totalSamples = chapters.reduce(0) { $0 + $1.sectors * CDDA.samplesPerSector }

        let writer = try AVAssetWriter(outputURL: partial, fileType: .m4v)
        let width = CDGraphicsScreen.width * scale
        let height = CDGraphicsScreen.height * scale
        var compression: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: Self.framesPerSecond,
            AVVideoMaxKeyFrameIntervalKey: 2 * Self.framesPerSecond,
            AVVideoQualityKey: 0.9,
        ]
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: compression,
        ]
        if !writer.canApply(outputSettings: videoSettings, forMediaType: .video) {
            compression[AVVideoQualityKey] = nil
            videoSettings[AVVideoCompressionPropertiesKey] = compression
        }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = false
        let frames = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])

        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        var audioSettings: [String: Any] = [
            AVSampleRateKey: CDGraphicsVideo.sampleRate, AVNumberOfChannelsKey: 2,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
        switch self.audio {
        case .appleLossless:
            audioSettings[AVFormatIDKey] = kAudioFormatAppleLossless
            audioSettings[AVEncoderBitDepthHintKey] = 16
        case .aac:
            audioSettings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            audioSettings[AVEncoderBitRateKey] = Self.aacBitRate
        }
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audio.expectsMediaDataInRealTime = false
        writer.metadata = [
            (AVMetadataIdentifier.commonIdentifierTitle, title),
            (.commonIdentifierArtist, artist),
        ].compactMap { identifier, value in
            value.map {
                let item = AVMutableMetadataItem()
                item.identifier = identifier
                item.value = $0 as NSString
                return item
            }
        }

        let (titles, titleFormat) = try Self.chapterSamples(chapters, width: width)
        let text = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: titleFormat)
        text.marksOutputTrackAsEnabled = false
        text.naturalSize = CGSize(width: width, height: Self.titleHeight)

        for input in [video, audio, text] {
            guard writer.canAdd(input) else {
                throw VideoError.writer("cannot add the \(input.mediaType.rawValue) track")
            }
            writer.add(input)
        }
        video.addTrackAssociation(withTrackOf: text, type: AVAssetTrack.AssociationType.chapterList.rawValue)
        audio.addTrackAssociation(withTrackOf: text, type: AVAssetTrack.AssociationType.chapterList.rawValue)
        guard writer.startWriting() else { throw VideoError.writer("\(writer.error.map { "\($0)" } ?? "unknown")") }
        writer.startSession(atSourceTime: .zero)

        var audioFormat: CMAudioFormatDescription?
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(CDGraphicsVideo.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &audioFormat)
        guard let audioFormat else { throw VideoError.writer("no audio format") }

        var screen = CDGraphicsScreen(extended: picture == .extended)
        var frame = 0
        var lastChanges = -1
        var lastBuffer: CVPixelBuffer?
        var pendingTitles = titles
        // The audio of the track under way, and where the next piece starts in it and in the disc.
        var chapterIndex = 0
        var samples = [UInt32]()
        var sampleInChapter = 0
        var written = 0
        let piece = CDGraphicsVideo.sampleRate / 10

        func fail() -> VideoError { .writer(writer.error.map { "\($0)" } ?? "unknown") }
        while frame < totalFrames || written < totalSamples || !pendingTitles.isEmpty {
            try stop?.check()
            guard writer.status == .writing else { throw fail() }
            let videoTime = Double(frame) / Double(Self.framesPerSecond)
            let audioTime = Double(written) / Double(CDGraphicsVideo.sampleRate)
            let videoFirst = frame < totalFrames && (written >= totalSamples || videoTime <= audioTime)
            if !pendingTitles.isEmpty, text.isReadyForMoreMediaData {
                guard text.append(pendingTitles.removeFirst()) else { throw fail() }
                if pendingTitles.isEmpty { text.markAsFinished() }
            } else if frame < totalFrames, video.isReadyForMoreMediaData, videoFirst || !audio.isReadyForMoreMediaData {
                // The screen after the frame's packs.
                let end = min((frame + 1) * Self.packsPerFrame, totalPacks)
                packs.withUnsafeBytes { bytes in
                    let all = bytes.bindMemory(to: UInt8.self)
                    for p in (frame * Self.packsPerFrame)..<end {
                        screen.apply(Array(all[(p * 24)..<(p * 24 + 24)]))
                    }
                }
                if screen.changes != lastChanges || lastBuffer == nil {
                    guard let pool = frames.pixelBufferPool else { throw fail() }
                    var buffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                    guard let buffer else { throw VideoError.writer("no pixel buffer") }
                    CVPixelBufferLockBaseAddress(buffer, [])
                    screen.drawBGRA(
                        into: CVPixelBufferGetBaseAddress(buffer)!, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                        scale: scale)
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    lastBuffer = buffer
                    lastChanges = screen.changes
                }
                let time = CMTime(value: Int64(frame), timescale: CMTimeScale(Self.framesPerSecond))
                guard frames.append(lastBuffer!, withPresentationTime: time) else { throw fail() }
                frame += 1
                if frame == totalFrames { video.markAsFinished() }
                if frame % Self.framesPerSecond == 0 {
                    progress(Double(frame) / Double(max(totalFrames, 1)))
                }
            } else if written < totalSamples, audio.isReadyForMoreMediaData {
                if sampleInChapter == samples.count {
                    samples = try chapters[chapterIndex].audio()
                    let expected = chapters[chapterIndex].sectors * CDDA.samplesPerSector
                    if samples.count != expected {
                        samples =
                            Array(samples.prefix(expected))
                            + [UInt32](repeating: 0, count: max(0, expected - samples.count))
                    }
                    chapterIndex += 1
                    sampleInChapter = 0
                }
                let count = min(piece, samples.count - sampleInChapter)
                let buffer = try Self.audioBuffer(
                    samples[sampleInChapter..<(sampleInChapter + count)], at: written, format: audioFormat)
                guard audio.append(buffer) else { throw fail() }
                sampleInChapter += count
                written += count
                if sampleInChapter == samples.count {
                    samples = []
                    sampleInChapter = 0
                }
                if written == totalSamples { audio.markAsFinished() }
            } else {
                usleep(500)
            }
        }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw fail() }
        progress(1)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        try fileManager.moveItem(at: partial, to: url)
    }

    /// The chapter track's height; it is not shown.
    static let titleHeight = 20

    /// The chapters' titles as 3GPP text samples, one for each chapter over its time, and
    /// their format.
    static func chapterSamples(_ chapters: [Chapter], width: Int) throws -> ([CMSampleBuffer], CMFormatDescription) {
        func color(_ value: Int) -> [String: Any] {
            [
                kCMTextFormatDescriptionColor_Red as String: value,
                kCMTextFormatDescriptionColor_Green as String: value,
                kCMTextFormatDescriptionColor_Blue as String: value, kCMTextFormatDescriptionColor_Alpha as String: 255,
            ]
        }
        // Every field: the text box must have a size, or the writer finds the format invalid.
        let extensions: [String: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags as String: 0,
            kCMTextFormatDescriptionExtension_BackgroundColor as String: color(0),
            kCMTextFormatDescriptionExtension_DefaultTextBox as String: [
                kCMTextFormatDescriptionRect_Top as String: 0, kCMTextFormatDescriptionRect_Left as String: 0,
                kCMTextFormatDescriptionRect_Bottom as String: titleHeight,
                kCMTextFormatDescriptionRect_Right as String: width,
            ],
            kCMTextFormatDescriptionExtension_DefaultStyle as String: [
                kCMTextFormatDescriptionStyle_StartChar as String: 0,
                kCMTextFormatDescriptionStyle_EndChar as String: 0,
                kCMTextFormatDescriptionStyle_Font as String: 1, kCMTextFormatDescriptionStyle_FontFace as String: 0,
                kCMTextFormatDescriptionStyle_FontSize as String: 12,
                kCMTextFormatDescriptionStyle_ForegroundColor as String: color(255),
            ],
            kCMTextFormatDescriptionExtension_HorizontalJustification as String: 0,
            kCMTextFormatDescriptionExtension_VerticalJustification as String: 0,
            kCMTextFormatDescriptionExtension_FontTable as String: ["1": "Sans-Serif"],
        ]
        var format: CMFormatDescription?
        CMFormatDescriptionCreate(
            allocator: nil, mediaType: kCMMediaType_Text, mediaSubType: kCMTextFormatType_3GText,
            extensions: extensions as CFDictionary, formatDescriptionOut: &format)
        guard let format else { throw VideoError.writer("no chapter format") }
        var start = 0
        let samples = try chapters.map { chapter -> CMSampleBuffer in
            // A 16-bit length, then the UTF-8.
            let utf8 = Array(chapter.title.utf8.prefix(0xFFFF))
            var bytes = [UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)] + utf8
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &block)
            guard let block else { throw VideoError.writer("no chapter buffer") }
            CMBlockBufferReplaceDataBytes(
                with: &bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
            // In sectors (1/75 second), so that each chapter starts exactly at its track.
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: Int64(chapter.sectors), timescale: CMTimeScale(CDDA.sectorsPerSecond)),
                presentationTimeStamp: CMTime(value: Int64(start), timescale: CMTimeScale(CDDA.sectorsPerSecond)),
                decodeTimeStamp: .invalid)
            start += chapter.sectors
            var size = bytes.count
            var sample: CMSampleBuffer?
            CMSampleBufferCreate(
                allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
            guard let sample else { throw VideoError.writer("no chapter sample") }
            return sample
        }
        return (samples, format)
    }

    /// 16-bit stereo samples (left in the low half, as `CDDA` has them) as a sample buffer at
    /// sample `position` of the video.
    static func audioBuffer(_ samples: ArraySlice<UInt32>, at position: Int, format: CMAudioFormatDescription)
        throws -> CMSampleBuffer
    {
        var block: CMBlockBuffer?
        let length = samples.count * 4
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block else { throw VideoError.writer("no audio buffer") }
        samples.map(\.littleEndian).withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: samples.count,
            presentationTimeStamp: CMTime(value: Int64(position), timescale: CMTimeScale(CDGraphicsVideo.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &buffer)
        guard let buffer else { throw VideoError.writer("no audio sample") }
        return buffer
    }
}
