import AudioToolbox

/// Where each speaker of surround audio goes in a format's channel layout. Silverside puts
/// the channels in the layout's order itself, and AudioToolbox converts no channels: its
/// conversion between layouts drops the surrounds of quad audio into FLAC (whose four
/// channels are rear ones) and moves them to the center in AAC, and its own read-back does
/// not tell (2026-10-29, found by a check with ffmpeg).
struct SurroundLayout: Equatable {
    /// The layout the file names, as the format's encoder takes it.
    var tag: AudioChannelLayoutTag
    /// For each of the layout's channels, the source channel it holds; nil for a silent one,
    /// where the format has no layout of just the source's speakers.
    var sources: [Int?]

    var channels: Int { sources.count }

    /// The layout for audio with `mask`'s speakers in `format`: the smallest of the encoder's
    /// layouts that has a place for each speaker. Nil for a format whose encoder takes any
    /// layout (AIFF), which keeps the source's channels as they are.
    static func of(mask: UInt32, format: AudioFormat) throws -> SurroundLayout? {
        guard let formatID = formatID(of: format) else { return nil }
        let speakers = Self.speakers(of: mask)
        for tag in encoderTags(formatID: formatID, channels: speakers.count) {
            if let sources = assign(speakers, to: labels(of: tag)) { return SurroundLayout(tag: tag, sources: sources) }
        }
        throw DTSError.noLayout(format, layout: SurroundPCM(values: [], channels: speakers.count, channelMask: mask))
    }

    /// The values in the layout's order, with zeros in its silent channels.
    func arrange(_ audio: SurroundPCM) -> [Int32] {
        var values = [Int32](repeating: 0, count: audio.frameCount * channels)
        for (channel, source) in sources.enumerated() {
            guard let source else { continue }
            var (from, to) = (source, channel)
            while from < audio.values.count {
                values[to] = audio.values[from]
                from += audio.channels
                to += channels
            }
        }
        return values
    }

    private static func formatID(of format: AudioFormat) -> AudioFormatID? {
        switch format {
        case .flac: kAudioFormatFLAC
        case .alac: kAudioFormatAppleLossless
        case .aac: kAudioFormatMPEG4AAC
        case .aiff, .wav, .mp3: nil
        }
    }

    /// The encoder's layouts with `channels` channels or more, fewest first. The encoders
    /// list them for every count.
    private static func encoderTags(formatID: AudioFormatID, channels: Int) -> [AudioChannelLayoutTag] {
        var format = AudioStreamBasicDescription()
        format.mFormatID = formatID
        format.mSampleRate = 44_100
        format.mChannelsPerFrame = UInt32(channels)
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var size: UInt32 = 0
        guard
            AudioFormatGetPropertyInfo(
                kAudioFormatProperty_AvailableEncodeChannelLayoutTags, formatSize, &format, &size) == noErr
        else { return [] }
        var tags = [AudioChannelLayoutTag](repeating: 0, count: Int(size) / MemoryLayout<AudioChannelLayoutTag>.size)
        guard
            AudioFormatGetProperty(
                kAudioFormatProperty_AvailableEncodeChannelLayoutTags, formatSize, &format, &size, &tags) == noErr
        else { return [] }
        var seen = Set<AudioChannelLayoutTag>()
        let unique = tags.filter { seen.insert($0).inserted }
        // The low 16 bits of a tag are its number of channels; the sort keeps the encoder's order within a count.
        return unique.filter { Int($0 & 0xFFFF) >= channels }.enumerated()
            .sorted { ($0.element & 0xFFFF, $0.offset) < ($1.element & 0xFFFF, $1.offset) }.map(\.element)
    }

    /// The speakers of a layout tag, as Core Audio's channel labels, in its channel order.
    static func labels(of tag: AudioChannelLayoutTag) -> [AudioChannelLabel] {
        var tag = tag
        var size: UInt32 = 0
        let tagSize = UInt32(MemoryLayout<AudioChannelLayoutTag>.size)
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, tagSize, &tag, &size) == noErr
        else { return [] }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { buffer.deallocate() }
        guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, tagSize, &tag, &size, buffer) == noErr
        else { return [] }
        return labels(ofDescriptions: buffer.assumingMemoryBound(to: AudioChannelLayout.self))
    }

    /// The labels of a layout that lists its channels.
    static func labels(ofDescriptions layout: UnsafePointer<AudioChannelLayout>) -> [AudioChannelLabel] {
        let count = Int(layout.pointee.mNumberChannelDescriptions)
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        let descriptions = (UnsafeRawPointer(layout) + offset).assumingMemoryBound(to: AudioChannelDescription.self)
        return (0..<count).map { descriptions[$0].mChannelLabel }
    }

    /// The speakers of a WAVE channel mask, in WAVE's channel order.
    static func speakers(of mask: UInt32) -> [UInt32] {
        (0..<32).map { UInt32(1) << $0 }.filter { mask & $0 != 0 }
    }

    /// Each speaker's place among the labels, or nil if one has none. A layout with one pair
    /// of surrounds takes them whether WAVE calls them back or side ones, as ffmpeg's DTS
    /// decode calls them side ones; with two pairs, the side pair goes to the surrounds and
    /// the back pair to the rear surrounds.
    static func assign(_ speakers: [UInt32], to labels: [AudioChannelLabel]) -> [Int?]? {
        let bothPairs = speakers.contains(0x10) && speakers.contains(0x200)
        let surround: [UInt32: [AudioChannelLabel]] =
            bothPairs
            ? [
                0x200: [kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect],
                0x400: [kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect],
                0x10: [kAudioChannelLabel_RearSurroundLeft], 0x20: [kAudioChannelLabel_RearSurroundRight],
            ]
            : [
                0x10: [
                    kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect,
                    kAudioChannelLabel_RearSurroundLeft,
                ],
                0x20: [
                    kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect,
                    kAudioChannelLabel_RearSurroundRight,
                ],
                0x200: [
                    kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect,
                    kAudioChannelLabel_RearSurroundLeft,
                ],
                0x400: [
                    kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect,
                    kAudioChannelLabel_RearSurroundRight,
                ],
            ]
        let fixed: [UInt32: AudioChannelLabel] = [
            0x1: kAudioChannelLabel_Left, 0x2: kAudioChannelLabel_Right, 0x4: kAudioChannelLabel_Center,
            0x8: kAudioChannelLabel_LFEScreen, 0x40: kAudioChannelLabel_LeftCenter,
            0x80: kAudioChannelLabel_RightCenter, 0x100: kAudioChannelLabel_CenterSurround,
        ]
        var sources = [Int?](repeating: nil, count: labels.count)
        for (index, speaker) in speakers.enumerated() {
            let wanted = surround[speaker] ?? fixed[speaker].map { [$0] } ?? []
            guard
                let place = wanted.lazy.compactMap({ label in
                    labels.indices.first { labels[$0] == label && sources[$0] == nil }
                }).first
            else { return nil }
            sources[place] = index
        }
        return sources
    }

    /// The WAVE speaker of each label, for a file read back: its surrounds are back ones,
    /// unless it has rear surrounds too, as FLAC's 7.1 does. Nil if a label has no WAVE speaker.
    static func speakers(of labels: [AudioChannelLabel]) -> [UInt32]? {
        let hasRear = labels.contains(kAudioChannelLabel_RearSurroundLeft)
        let bits: [AudioChannelLabel: UInt32] = [
            kAudioChannelLabel_Left: 0x1, kAudioChannelLabel_Right: 0x2, kAudioChannelLabel_Center: 0x4,
            kAudioChannelLabel_LFEScreen: 0x8, kAudioChannelLabel_LeftCenter: 0x40,
            kAudioChannelLabel_RightCenter: 0x80, kAudioChannelLabel_CenterSurround: 0x100,
            kAudioChannelLabel_LeftSurround: hasRear ? 0x200 : 0x10,
            kAudioChannelLabel_RightSurround: hasRear ? 0x400 : 0x20,
            kAudioChannelLabel_LeftSurroundDirect: hasRear ? 0x200 : 0x10,
            kAudioChannelLabel_RightSurroundDirect: hasRear ? 0x400 : 0x20,
            kAudioChannelLabel_RearSurroundLeft: 0x10, kAudioChannelLabel_RearSurroundRight: 0x20,
        ]
        let speakers = labels.compactMap { bits[$0] }
        guard speakers.count == labels.count, Set(speakers).count == speakers.count else { return nil }
        return speakers
    }
}
