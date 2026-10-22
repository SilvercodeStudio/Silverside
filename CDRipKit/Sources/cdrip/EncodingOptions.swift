import ArgumentParser
import CDRipKit
import Foundation

/// The options for encoding, shared by `encode` and `rip --encode`. Each one that is not
/// given comes from the settings file (see `silverside config`).
struct EncodingOptions: ParsableArguments {
    @Option(help: "The format. MP3 needs the lame program.")
    var format: AudioFormat?

    @Option(name: .shortAndLong, help: "The music library's folder.")
    var library: String?

    @Option(help: "The album folder's template, in the library, such as \"{albumArtist}/{album}\".")
    var folderTemplate: String?

    @Option(help: "Each track's file name template, with no extension, such as \"[{disc:2}-]{track} {title}\".")
    var trackTemplate: String?

    @Flag(
        inversion: .prefixedNo,
        help: "For live shows whose disc titles have a date and venue, add \"[Venue, M-D-YY]\" to titles.")
    var liveShowStyle: Bool?

    @Flag(inversion: .prefixedNo, help: "Turn typographic punctuation into ASCII in names and tags (’ becomes ').")
    var plainPunctuation: Bool?

    @Option(help: "Where the \">\" at the end of a title goes: everywhere (tags and file names), tags, or none.")
    var segueMarks: SegueMarks?

    @Option(help: "The folder for compilations in the library, in place of \"Various Artists\".")
    var compilationFolder: String?

    @Option(help: "The AAC mode: constant, average, or variable bit rate; vbr-constrained is Apple's choice.")
    var aacMode: AACOptions.Mode?

    @Option(help: "The AAC bit rate, in kbit/s (not used in vbr mode).")
    var aacBitrate: Int?

    @Option(help: "The AAC quality in vbr mode, from 0 to 127 (the best).")
    var aacQuality: Int?

    @Option(help: "The MP3 mode: vbr (from --mp3-quality), or cbr and abr (from --mp3-bitrate).")
    var mp3Mode: MP3Options.Mode?

    @Option(help: "The MP3 bit rate, in kbit/s, for cbr and abr.")
    var mp3Bitrate: Int?

    @Option(help: "The MP3 VBR preset, from 0 (the best) to 9: lame's -V.")
    var mp3Quality: Int?

    @Option(help: "One more option for lame, such as --lame-option=-q --lame-option=0. Give it once for each word.")
    var lameOption: [String] = []

    /// The encoder, and the library, from these options over the settings.
    func encoder(_ settings: Settings) -> (encoder: DiscEncoder, library: URL) {
        var encoder = DiscEncoder(settings: settings, format: format)
        if let folderTemplate { encoder.folderTemplate = NameTemplate(folderTemplate) }
        if let trackTemplate { encoder.trackTemplate = NameTemplate(trackTemplate) }
        if let liveShowStyle { encoder.liveShowStyle = liveShowStyle }
        if let plainPunctuation { encoder.plainPunctuation = plainPunctuation }
        if let segueMarks { encoder.segueMarks = segueMarks }
        if let compilationFolder { encoder.compilationFolder = compilationFolder }
        if let aacMode { encoder.aac.mode = aacMode }
        if let aacBitrate { encoder.aac.bitRate = aacBitrate }
        if let aacQuality { encoder.aac.vbrQuality = aacQuality }
        if let mp3Mode { encoder.mp3.mode = mp3Mode }
        if let mp3Bitrate { encoder.mp3.bitRate = mp3Bitrate }
        if let mp3Quality { encoder.mp3.vbrQuality = mp3Quality }
        if !lameOption.isEmpty { encoder.mp3.extraArguments = lameOption }
        return (encoder, library.map(Settings.expand) ?? settings.libraryURL)
    }
}

extension AudioFormat: ExpressibleByArgument {}
extension AACOptions.Mode: ExpressibleByArgument {}
extension MP3Options.Mode: ExpressibleByArgument {}
extension ArtworkChoice: ExpressibleByArgument {}
extension SegueMarks: ExpressibleByArgument {}
