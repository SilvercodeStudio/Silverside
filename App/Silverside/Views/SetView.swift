import SilversideKit
import SwiftUI
import UniformTypeIdentifiers

/// A multi-disc release among the earlier rips: each disc's state, the album's names, which
/// every disc shares, and the work that brings the set into the library.
struct SetView: View {
    @Environment(AppModel.self) private var model
    let ripSet: RipSet
    @State private var cover: Data?
    @State private var coverTargeted = false
    @State private var album = ""
    @State private var albumArtist = ""
    @State private var date = ""

    /// The release, from the newest disc's report.
    private var release: MusicBrainzRelease? {
        ripSet.discs.values.sorted { $0.date > $1.date }.lazy.compactMap { disc in
            model.recentRips.first { $0.file == disc.file }?.report.release
        }.first
    }

    private var edits: MetadataEdits { ReleaseEditsStore().edits(forReleaseID: ripSet.releaseID) ?? MetadataEdits() }

    private func rip(at position: Int) -> RecentRip? {
        guard let disc = ripSet.discs[position] else { return nil }
        return model.recentRips.first { $0.file == disc.file }
    }

    /// Discs that are verified, with their WAV files, and not in the library.
    private var toEncode: [RecentRip] {
        ripSet.positions.compactMap { position in
            guard let disc = ripSet.discs[position], disc.hasAudio, disc.isVerified, !disc.isEncoded else { return nil }
            return rip(at: position)
        }
    }

    private var encoded: [RecentRip] {
        ripSet.positions.compactMap { position in
            guard let disc = ripSet.discs[position], disc.isEncoded else { return nil }
            return rip(at: position)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            Divider()
            table
        }
        .navigationTitle(ripSet.title)
        .navigationSubtitle(ripSet.artist)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.startLibraryRun(title: ripSet.title, encode: toEncode, update: [])
                } label: {
                    Label("Encode \(Format.count(toEncode.count, "Disc"))", systemImage: "music.note.list")
                }
                .disabled(toEncode.isEmpty || model.library?.isRunning == true)
                .help(
                    toEncode.isEmpty
                        ? "Every verified disc of the set is in the library"
                        : "Encode the verified discs that are not in the library yet, as Settings say")
                Button {
                    model.startLibraryRun(title: ripSet.title, encode: [], update: encoded)
                } label: {
                    Label("Update the Library", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(encoded.isEmpty || model.library?.isRunning == true)
                .help(
                    "Write the album's names and cover into every encoded disc's files, and rename them as the templates say"
                )
                InfoButton(title: "Set Info", help: "The release as MusicBrainz has it") {
                    release.map { InfoSection.disc(release: $0) } ?? []
                }
            }
        }
        .task(id: "\(ripSet.releaseID) \(model.coverVersion)") {
            cover =
                ripSet.discs.values.sorted { $0.date > $1.date }.lazy.compactMap { disc in
                    ["cover.jpg", "cover.png"].lazy.compactMap {
                        try? Data(contentsOf: disc.folder.appending(path: $0))
                    }.first
                }.first ?? ReleaseCoverStore().cover(forReleaseID: ripSet.releaseID)?.data
        }
        .onAppear(perform: loadFields)
        .onChange(of: ripSet.releaseID) { loadFields() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverView(data: cover)
                .overlay {
                    if coverTargeted {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
                .onDrop(of: [.fileURL, .image], isTargeted: $coverTargeted) { providers in
                    guard let provider = providers.first else { return false }
                    CoverDrop.load(provider) { data in
                        if let data { changeCover(to: CoverImage(data: data)) }
                    }
                    return true
                }
                .onTapGesture(perform: chooseCover)
                .contextMenu {
                    Button("Choose Cover…", action: chooseCover)
                    if release?.hasFrontCover == true {
                        Button("Use the Cover Art Archive's") { changeCover(to: nil) }
                    }
                    Divider()
                    Button("Export Cover…") {
                        CoverDrop.export(cover, name: "\(ripSet.artist) - \(ripSet.title) cover")
                    }
                    .disabled(cover == nil)
                }
                .help(
                    "Drop an image here, or click, to give every disc of the set this cover: in the rips, the album folder, and the files' tags."
                )
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 16) {
                    field("Album", text: $album, prompt: release?.title ?? ripSet.title)
                    field("Album Artist", text: $albumArtist, prompt: release?.artist ?? ripSet.artist)
                    field("Date", text: $date, prompt: release?.date ?? "").frame(width: 140)
                }
                Text(
                    "The names are the set's: every disc takes them. Press Return to keep a change, then Update the Library to write it into the encoded files."
                )
                .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Chip(
                        text: ripSet.isComplete
                            ? "All \(ripSet.discCount) discs verified and encoded"
                            : "\(ripSet.discs.count) of \(ripSet.discCount) discs ripped",
                        tone: ripSet.isComplete ? .good : .neutral, systemImage: "square.stack")
                    if let release, let label = release.labels.compactMap(\.name).first { Chip(text: label) }
                    if let genre = release?.genre { Chip(text: genre, systemImage: "music.note.list") }
                    if !edits.isEmpty { Chip(text: "Edited", tone: .warning, systemImage: "pencil") }
                }
                Text(ripSet.summary).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveFields)
        }
    }

    /// A row for each disc, with its tracks under it: from the rip's report when the disc is
    /// ripped, else from MusicBrainz.
    private var rows: [SetRow] {
        ripSet.positions.map { position in
            let disc = ripSet.discs[position]
            let report = disc.flatMap { _ in rip(at: position)?.report }
            let medium = report?.medium ?? release?.media.first { $0.position == position }
            let tracks: [SetRow]
            if let report {
                let titles = medium?.tracks.map(\.title) ?? []
                tracks = report.tracks.enumerated().map { index, track in
                    SetRow(
                        position: position, number: track.number,
                        title: index < titles.count ? titles[index] : track.file,
                        seconds: track.sectors / CDDA.sectorsPerSecond, track: track, ctdb: report.ctdb)
                }
            } else {
                tracks = (medium?.tracks ?? []).map { track in
                    SetRow(
                        position: position, number: track.position, title: track.title,
                        seconds: track.length.map { $0 / 1000 })
                }
            }
            let seconds = tracks.compactMap(\.seconds).reduce(0, +)
            return SetRow(
                position: position, title: medium?.title ?? Format.count(tracks.count, "track"),
                seconds: tracks.isEmpty ? nil : seconds, disc: disc, report: report,
                children: tracks.isEmpty ? nil : tracks)
        }
    }

    @State private var selectedRows = Set<SetRow.ID>()

    private var table: some View {
        Table(rows, children: \.children, selection: $selectedRows) {
            TableColumn("Disc") { row in
                if let number = row.number {
                    Text(String(number)).foregroundStyle(.tertiary)
                } else {
                    Text(String(row.position)).foregroundStyle(.secondary)
                }
            }
            .width(min: 64, ideal: 72)
            TableColumn("Title") { row in
                Text(row.title).foregroundStyle(row.number == nil || row.track != nil ? .primary : .secondary)
            }
            .width(min: 160, ideal: 280)
            TableColumn("Time") { row in
                if let seconds = row.seconds { Text(Format.duration(seconds: seconds)).foregroundStyle(.secondary) }
            }
            .width(min: 52, ideal: 64)
            TableColumn("State") { row in
                if let track = row.track {
                    FinishedStatus(track: track, ctdb: row.ctdb)
                } else if row.number != nil {
                    EmptyView()
                } else if let disc = row.disc {
                    Label(
                        disc.stateText.prefix(1).uppercased() + disc.stateText.dropFirst(),
                        systemImage: disc.isFinished ? "checkmark.circle" : "circle"
                    )
                    .foregroundStyle(disc.isFinished ? Theme.good : disc.isVerified ? Theme.warning : Theme.bad)
                } else {
                    Label("Still to do", systemImage: "circle.dashed").foregroundStyle(.secondary)
                }
            }
            .width(min: 160, ideal: 200)
            TableColumn("Ripped") { row in
                if row.number == nil, let disc = row.disc { DateCell(date: disc.date) }
            }
            .width(min: 140, ideal: 170)
            TableColumn("Drive") { row in
                if row.number == nil, let report = row.report {
                    Text("\(report.drive.vendor) \(report.drive.product)").foregroundStyle(.secondary)
                }
            }
            .width(min: 140, ideal: 220)
            TableColumn("") { row in
                if row.number == nil, let disc = row.disc {
                    Button("Show") { model.selection = .rip(disc.file) }.buttonStyle(.link)
                }
            }
            .width(60)
        }
        .contextMenu(forSelectionType: SetRow.ID.self) { ids in
            if let file = file(ofDiscIn: ids) {
                Button("Show Disc") { model.selection = .rip(file) }
            }
        } primaryAction: { ids in
            if let file = file(ofDiscIn: ids) { model.selection = .rip(file) }
        }
        .alternatingRowBackgrounds(.disabled)
    }

    /// The report file of the disc that the rows are in or under, when they are all one ripped disc's.
    private func file(ofDiscIn ids: Set<SetRow.ID>) -> URL? {
        let positions = Set(ids.map(\.position))
        guard positions.count == 1, let position = positions.first else { return nil }
        return ripSet.discs[position]?.file
    }

    /// A disc of the set, or (with a number) one of its tracks.
    private struct SetRow: Identifiable {
        struct ID: Hashable {
            var position: Int
            var number: Int?
        }
        var position: Int
        /// The track's number; nil for a disc.
        var number: Int?
        var title: String
        var seconds: Int?
        var disc: RipSet.Disc?
        var report: RipReport?
        /// The track's result, when its disc is ripped.
        var track: RipReport.Track?
        var ctdb: RipReport.CTDBResult?
        var children: [SetRow]?
        var id: ID { ID(position: position, number: number) }
    }

    private func loadFields() {
        let edits = self.edits
        album = edits.album ?? ""
        albumArtist = edits.albumArtist ?? ""
        date = edits.date ?? ""
    }

    private func saveFields() {
        func value(_ text: String, original: String?) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed == original ? nil : trimmed
        }
        var edits = self.edits
        edits.album = value(album, original: release?.title)
        edits.albumArtist = value(albumArtist, original: release?.artist)
        edits.date = value(date, original: release?.date)
        do {
            try ReleaseEditsStore().remember(edits, forReleaseID: ripSet.releaseID)
            loadFields()
        } catch {
            model.alert = AppAlert(title: "The names could not be saved", message: "\(error)")
        }
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message =
            "Choose an image for the set's cover. JPEG and PNG are kept as they are; other formats become JPEG."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = CoverDrop.imageData(from: url) { changeCover(to: CoverImage(data: data)) }
    }

    /// A cover for every disc: the encoded ones through a library update, the others through
    /// their rip folders; nil takes the Cover Art Archive's front cover.
    private func changeCover(to image: CoverImage?) {
        let rips = ripSet.positions.compactMap(rip(at:))
        model.changeCover(ofSet: ripSet, rips: rips, to: image)
    }
}
