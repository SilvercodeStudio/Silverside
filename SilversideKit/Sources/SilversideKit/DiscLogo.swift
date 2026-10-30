import Foundation

/// The logo that a disc of its kind carries on its label, for the app to show: one, the
/// most telling of those that fit (`logo(toc:format:media:hasCDText:probe:)`).
public enum DiscLogo: String, CaseIterable, Sendable {
    case dts
    case hdcd
    /// The CD layer of a hybrid Super Audio CD.
    case sacd
    /// CD+Graphics.
    case cdGraphics
    /// The "disc+" logo of an Enhanced CD (Blue Book, CD Extra): music, then data in a second session.
    case compactDiscPlus
    /// A Mixed Mode CD: data in track 1, then music. It has no logo of its own; it gets the
    /// "disc+" logo too, as a disc that is more than music, and its name says which kind it is.
    case mixedMode
    /// A recordable disc (CD-R), as a burned copy or a small release is.
    case recordable
    /// A disc with CD-Text.
    case cdText
    /// Compact Disc Digital Audio (Red Book).
    case compactDisc
    /// Discs that are not CDs, which Silverside does not rip: a DVD (video or data), a
    /// DVD-Audio disc, a Blu-ray disc, and an Ultra HD (4K) Blu-ray disc.
    case dvd
    case dvdAudio
    case bluRay
    case ultraHDBluRay

    /// The disc's logo: the first in this order that fits. What the audio is goes before what
    /// the disc is, so a CD-R of an HDCD disc gets the HDCD logo. `format` is MusicBrainz's
    /// format for the disc's medium, `media` what the drive says the disc is, and `probe` what
    /// a look at the audio found (`DiscProbe`), or a rip: what is found counts, and
    /// MusicBrainz's format where nothing could be.
    public static func logo(
        toc: TOC, format: String?, media: DiscMediaType? = nil, hasCDText: Bool = false, probe: DiscProbe? = nil
    ) -> DiscLogo {
        let format = format?.uppercased() ?? ""
        // MusicBrainz's word counts until the audio was looked at.
        let looked = (probe?.tracksRead ?? 0) > 0
        let found = probe ?? DiscProbe(tracksRead: 0)
        if found.dts || (!looked && format == "DTS CD") { return .dts }
        if found.hdcd || (!looked && format == "HDCD") { return .hdcd }
        if format.contains("SACD") { return .sacd }
        if found.cdGraphics ?? (format == "CD+G") { return .cdGraphics }
        if toc.isEnhanced || format == "ENHANCED CD" { return .compactDiscPlus }
        if toc.tracks.first?.kind == .data || format == "MIXED MODE CD" { return .mixedMode }
        if media == .recordable || format == "CD-R" { return .recordable }
        if hasCDText { return .cdText }
        return .compactDisc
    }

    /// The logo of a disc that is not a CD, from the medium and its mounted volume. A Blu-ray
    /// disc is Ultra HD when its BDMV/index.bdmv says version 0300, as the Ultra HD Blu-ray
    /// format has it ("INDX0300": *Oppenheimer*; "INDX0200" on a Blu-ray disc, 2026-10-29). A
    /// DVD is DVD-Audio when it has DVD-Audio's titles (AUDIO_TS with an .IFO file: a DVD-Video
    /// disc often has an empty AUDIO_TS folder).
    public static func otherDisc(isBluRay: Bool, volume: URL?) -> DiscLogo {
        if isBluRay {
            let index = volume.flatMap { FileHandle(forReadingAtPath: $0.appending(path: "BDMV/index.bdmv").path) }
            defer { try? index?.close() }
            let header = (try? index?.read(upToCount: 8)).flatMap { $0 }
            return header == Data("INDX0300".utf8) ? .ultraHDBluRay : .bluRay
        }
        guard let volume else { return .dvd }
        let manager = FileManager.default
        let folder = ((try? manager.contentsOfDirectory(atPath: volume.path)) ?? [])
            .first { $0.uppercased() == "AUDIO_TS" }
        let titles = folder.flatMap { try? manager.contentsOfDirectory(atPath: volume.appending(path: $0).path) } ?? []
        return titles.contains { $0.uppercased().hasSuffix(".IFO") } ? .dvdAudio : .dvd
    }

    /// What the logo says, for a tooltip and for VoiceOver.
    public var name: String {
        switch self {
        case .dts: "DTS Digital Surround"
        case .hdcd: "HDCD"
        case .sacd: "Super Audio CD, its CD layer"
        case .cdGraphics: "CD+Graphics"
        case .compactDiscPlus: "Enhanced CD (CD Extra): music, then data in a session of its own"
        case .mixedMode: "Mixed Mode CD: data in track 1, then music"
        case .recordable: "Compact Disc Recordable (CD-R)"
        case .cdText: "Compact Disc Digital Audio, with CD-Text"
        case .compactDisc: "Compact Disc Digital Audio"
        case .dvd: "DVD"
        case .dvdAudio: "DVD-Audio"
        case .bluRay: "Blu-ray Disc"
        case .ultraHDBluRay: "Ultra HD Blu-ray"
        }
    }
}
