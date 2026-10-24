import SilversideKit
import SwiftUI

/// One line of a popover of facts: a label and its value.
struct InfoRow: Identifiable {
    let label: String
    let value: String
    var id: String { label + value }
}

/// A group of facts with a heading, such as "Release" or "Tags in file".
struct InfoSection: Identifiable {
    var title: String?
    var rows: [InfoRow]
    var id: String { title ?? "" }
}

/// A button that shows facts in a popover: everything known about a track or a disc, from
/// MusicBrainz, from the disc itself, from the rip, and from an encoded file's own tags.
struct InfoButton: View {
    /// Text beside the symbol, for a toolbar; nil for a plain symbol in a table row.
    var title: String?
    var help = "Info"
    /// The sections are built when the popover opens: reading a file's tags is for then.
    let sections: () -> [InfoSection]
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            if let title {
                Label(title, systemImage: "info.circle")
            } else {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(title == nil ? AnyButtonStyle(.plain) : AnyButtonStyle(.automatic))
        .help(help)
        .popover(isPresented: $shown, arrowEdge: title == nil ? .trailing : .bottom) {
            InfoPopover(sections: sections())
        }
    }
}

/// The popover's content: each section as a heading and a two-column grid.
private struct InfoPopover: View {
    let sections: [InfoSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 6) {
                    if let heading = section.title {
                        Text(heading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                        ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                Text(row.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                Text(row.value).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
        .font(.callout)
        .padding(16)
        .frame(minWidth: 300, maxWidth: 560, alignment: .leading)
    }
}

/// A button style chosen at run time: plain in a table row, the usual one in a toolbar.
private struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init(_ style: some PrimitiveButtonStyle) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

extension InfoSection {
    // MARK: Tracks

    /// A track of the disc in a drive.
    static func track(_ track: DiscInfo.Track, disc: DiscInfo) -> [InfoSection] {
        var rows = [InfoRow(label: "Title", value: track.title)]
        rows.append(.init(label: "Artist", value: track.artist ?? disc.artist))
        rows += credits(composers: track.composers, lyricists: track.lyricists)
        if let genre = disc.shownRelease?.genre { rows.append(.init(label: "Genre", value: genre)) }
        rows.append(.init(label: "Length", value: track.duration))
        if let isrc = track.isrc { rows.append(.init(label: "ISRC", value: isrc)) }
        if let id = track.recordingID { rows.append(.init(label: "Recording", value: id)) }
        return [InfoSection(title: nil, rows: rows)]
    }

    /// A track of an earlier rip, from its report, and the tags of its encoded file if there is one.
    static func track(_ track: RipReport.Track, report: RipReport, title: String?, file: URL?) -> [InfoSection] {
        var rows = [InfoRow(label: "Title", value: title ?? track.file)]
        let toc = try? TOC(ctdbTOCString: report.toc)
        let medium = toc.flatMap { report.release?.medium(for: $0) }
        let index = toc?.audioTracks.firstIndex { $0.number == track.number }
        let named = index.flatMap { index in
            medium.flatMap { $0.tracks.indices.contains(index) ? $0.tracks[index] : nil }
        }
        if let artist = named?.artist ?? report.release?.artist { rows.append(.init(label: "Artist", value: artist)) }
        rows += credits(composers: named?.composers ?? [], lyricists: named?.lyricists ?? [])
        if let genre = report.release?.genre { rows.append(.init(label: "Genre", value: genre)) }
        rows.append(.init(label: "Length", value: Format.duration(sectors: track.sectors)))
        if let isrc = track.isrc { rows.append(.init(label: "ISRC", value: isrc)) }
        if let id = named?.recordingID { rows.append(.init(label: "Recording", value: id)) }
        if let crc = track.crc32 { rows.append(.init(label: "CRC32", value: crc)) }
        if let test = track.testCRC32 {
            rows.append(.init(label: "Test read", value: test + (track.testReadMatches == false ? " (differs)" : "")))
        }
        var sections = [InfoSection(title: nil, rows: rows)]
        if let file, let tags = fileTags(file) {
            sections.append(InfoSection(title: "Tags in \(file.lastPathComponent)", rows: tags))
        }
        return sections
    }

    private static func credits(composers: [MusicBrainzRelease.Writer], lyricists: [MusicBrainzRelease.Writer])
        -> [InfoRow]
    {
        var rows = [InfoRow]()
        if !composers.isEmpty {
            rows.append(.init(label: "Composer", value: composers.map(\.shownName).joined(separator: ", ")))
        }
        if !lyricists.isEmpty {
            rows.append(.init(label: "Lyricist", value: lyricists.map(\.shownName).joined(separator: ", ")))
        }
        return rows
    }

    /// The tags in an encoded file, as a player reads them. Nil for a WAV file, or a file that cannot be read.
    static func fileTags(_ url: URL) -> [InfoRow]? {
        let comments: [(key: String, value: String)]
        do {
            switch url.pathExtension.lowercased() {
            case "flac": comments = try FLACTags.read(url)
            case "m4a", "mp4": comments = try MP4Tags.read(url).comments
            case "mp3":
                comments = try ID3Tags.readTextFrames(url).sorted { $0.key < $1.key }.map {
                    (Self.id3Names[$0.key] ?? $0.key, $0.value)
                }
            default: return nil
            }
        } catch {
            return [InfoRow(label: "Tags", value: "cannot be read: \(error)")]
        }
        return comments.map { InfoRow(label: $0.key, value: $0.value) }
    }

    /// ID3 frames by their Vorbis comment names, so that every format reads the same.
    private static let id3Names: [String: String] = [
        "TIT2": "TITLE", "TPE1": "ARTIST", "TPE2": "ALBUMARTIST", "TALB": "ALBUM", "TDRC": "DATE",
        "TDOR": "ORIGINALDATE", "TSST": "DISCSUBTITLE", "TSRC": "ISRC", "TPUB": "LABEL", "TCON": "GENRE",
        "TCMP": "COMPILATION", "TCOM": "COMPOSER", "TEXT": "LYRICIST", "TSOP": "ARTISTSORT",
        "TSO2": "ALBUMARTISTSORT", "TRCK": "TRACKNUMBER", "TPOS": "DISCNUMBER",
    ]

    // MARK: Discs

    /// The disc in a drive: its release as MusicBrainz has it, and the disc itself.
    static func disc(_ disc: DiscInfo) -> [InfoSection] {
        self.disc(
            release: disc.shownRelease, medium: disc.shownMedium, toc: disc.toc, mcn: disc.mcn, cdText: disc.cdText,
            media: disc.media)
    }

    /// A release alone, for a set.
    static func disc(release: MusicBrainzRelease) -> [InfoSection] {
        disc(release: release, medium: nil, toc: nil, mcn: nil, cdText: nil, media: nil)
    }

    /// An earlier rip's disc, from its report.
    static func disc(report: RipReport) -> [InfoSection] {
        let toc = try? TOC(ctdbTOCString: report.toc)
        return disc(
            release: report.release, medium: toc.flatMap { report.release?.medium(for: $0) }, toc: toc,
            mcn: report.mcn, cdText: report.cdText, media: report.media)
    }

    private static func disc(
        release: MusicBrainzRelease?, medium: MusicBrainzRelease.Medium?, toc: TOC?, mcn: String?, cdText: CDText?,
        media: DiscMediaType?
    ) -> [InfoSection] {
        var sections = [InfoSection]()
        if let release {
            var rows = [InfoRow(label: "Title", value: release.title), .init(label: "Artist", value: release.artist)]
            if let sort = MusicBrainzRelease.sortName(release.artistCredit), sort != release.artist {
                rows.append(.init(label: "Sort as", value: sort))
            }
            if let date = release.date { rows.append(.init(label: "Date", value: date)) }
            if let group = release.releaseGroup {
                let type = ([group.primaryType] + group.secondaryTypes.map { Optional($0) }).compactMap { $0 }
                    .joined(separator: ", ")
                var value = type.isEmpty ? group.title : type
                if let first = group.firstReleaseDate, !first.isEmpty, first != release.date {
                    value += " · first released \(first)"
                }
                rows.append(.init(label: "Release group", value: value))
            }
            if let status = release.status { rows.append(.init(label: "Status", value: status)) }
            if let country = release.country { rows.append(.init(label: "Country", value: country)) }
            if let barcode = release.barcode, !barcode.isEmpty { rows.append(.init(label: "Barcode", value: barcode)) }
            for label in release.labels {
                let value = [label.name, label.catalogNumber].compactMap { $0 }.joined(separator: " ")
                if !value.isEmpty { rows.append(.init(label: "Label", value: value)) }
            }
            if let note = release.disambiguation { rows.append(.init(label: "Note", value: note)) }
            if let genre = release.genre { rows.append(.init(label: "Genre", value: genre)) }
            if release.media.count > 1 {
                let position = medium.map { "Disc \($0.position) of " } ?? ""
                rows.append(.init(label: "Discs", value: position + String(release.media.count)))
            }
            if let title = medium?.title { rows.append(.init(label: "Disc title", value: title)) }
            if let format = medium?.format { rows.append(.init(label: "Format", value: format)) }
            if let count = release.artworkCount, count > 0 {
                rows.append(
                    .init(label: "Cover art", value: Format.count(count, "image") + " in the Cover Art Archive"))
            }
            if !release.isManual { rows.append(.init(label: "MusicBrainz", value: release.id)) }
            sections.append(InfoSection(title: "Release", rows: rows))
        }
        var rows = [InfoRow]()
        if let toc {
            let audio = toc.audioTracks
            let sectors = audio.reduce(0) { $0 + toc.sectorRange(of: $1).count }
            rows.append(.init(label: "Tracks", value: "\(audio.count) · \(Format.duration(sectors: sectors))"))
            if toc.isEnhanced { rows.append(.init(label: "Data track", value: "yes, after the audio")) }
            let emphasis = audio.filter(\.hasPreEmphasis).map { String($0.number) }
            if !emphasis.isEmpty {
                rows.append(.init(label: "Pre-emphasis", value: "tracks " + emphasis.joined(separator: ", ")))
            }
            rows.append(.init(label: "MusicBrainz disc ID", value: toc.musicBrainzDiscID))
            rows.append(.init(label: "freedb disc ID", value: String(format: "%08x", toc.freedbDiscID)))
            rows.append(.init(label: "AccurateRip disc ID", value: toc.accurateRipDiscID.name))
            rows.append(.init(label: "CTDB TOC", value: toc.ctdbTOCString))
        }
        if let mcn { rows.append(.init(label: "MCN", value: mcn)) }
        if let cdText {
            let text = [cdText.performers[0], cdText.titles[0]].compactMap { $0 }.joined(separator: " - ")
            rows.append(.init(label: "CD-Text", value: text.isEmpty ? "tracks only" : text))
        }
        if let media { rows.append(.init(label: "Media", value: "\(media)")) }
        if !rows.isEmpty { sections.append(InfoSection(title: "Disc", rows: rows)) }
        return sections
    }
}
