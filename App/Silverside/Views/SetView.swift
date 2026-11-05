import QuickLook
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
    /// The cover's file while Quick Look shows it.
    @State private var coverPreview: URL?
    /// The other images in an Artwork folder of the set's rips, which Quick Look shows after the cover.
    @State private var artwork: [URL] = []
    /// What Quick Look shows: the cover's file, then the Artwork folder's images.
    @State private var previewItems: [URL] = []
    @State private var archivePickerShown = false
    /// The other images of a release, offered for the discs' Artwork folders.
    @State private var artworkOffer: ArtworkOffer?
    @State private var album = ""
    @State private var albumArtist = ""
    @State private var date = ""
    /// The name field being edited: a name is kept when it is left, as when Return is pressed.
    @FocusState private var focusedField: String?
    /// The set whose names the fields hold.
    @State private var fieldsReleaseID: String?
    /// The set's ReplayGain, from the reports in its album folder.
    @State private var replayGain: SetReplayGain?

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

    /// Discs that Check Again may find more for, such as a new release's.
    private var toCheck: [RecentRip] {
        ripSet.positions.compactMap { rip(at: $0) }.filter(\.canCheckAgain)
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
                    // A name typed and not yet kept goes into the files too, as it shows.
                    saveFields()
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
                    saveFields()
                    model.startLibraryRun(title: ripSet.title, encode: [], update: encoded)
                } label: {
                    Label("Update the Library", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(encoded.isEmpty || model.library?.isRunning == true)
                .help(
                    "Write the album's names and cover into every encoded disc's files, and rename them as the templates say"
                )
                if !toCheck.isEmpty {
                    Button {
                        model.checkAgain(toCheck)
                    } label: {
                        Label("Check Again", systemImage: "arrow.clockwise")
                    }
                    .disabled(toCheck.allSatisfy { model.checking.contains($0.file) })
                    .help(
                        "Look \(Format.count(toCheck.count, "disc")) up in AccurateRip and CTDB again, for results that came since they were ripped, and check their audio against them"
                    )
                }
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
            artwork = CoverFiles.artwork(in: ArtworkOffer.folders(of: setRips))
            previewItems = (CoverDrop.file(for: cover, name: coverFileName).map { [$0] } ?? []) + artwork
        }
        .task(id: "\(ripSet.releaseID) \(model.recentRips.count) \(model.library?.isRunning == true)") {
            guard let release else {
                replayGain = nil
                return
            }
            // The album folders that the discs' reports name; a kept rip's may be out of date.
            let folders = ripSet.positions.compactMap { position -> [URL]? in
                guard let disc = ripSet.discs[position] else { return nil }
                let named = rip(at: position)?.report.encoding.map { URL(filePath: $0.folder) }
                return [named, disc.folder].compactMap { $0 }
            }.flatMap { $0 }
            replayGain = await Task.detached { RipSet.replayGain(of: release, folders: folders) }.value
        }
        .onAppear(perform: loadFields)
        .onChange(of: ripSet.releaseID) { loadFields() }
        .onChange(of: focusedField) { left, _ in
            if left != nil { saveFields() }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverView(data: cover)
                .overlay(alignment: .bottomTrailing) {
                    CoverArchiveBadge(release: release) { archivePickerShown = true }
                }
                .overlay(alignment: .bottomLeading) {
                    ArtworkBadge(count: artwork.count) { coverPreview = artwork.first }
                }
                .overlay {
                    if coverTargeted {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
                .onDrop(of: [.fileURL, .image], isTargeted: $coverTargeted) { providers in
                    guard let provider = providers.first else { return false }
                    CoverDrop.load(provider) { changeCover(to: CoverImage(data: $0)) }
                    return true
                }
                .onTapGesture {
                    if cover != nil {
                        coverPreview = CoverDrop.file(for: cover, name: coverFileName)
                    } else {
                        chooseCover()
                    }
                }
                .quickLookPreview($coverPreview, in: previewItems)
                .contextMenu {
                    Button("Quick Look") { coverPreview = CoverDrop.file(for: cover, name: coverFileName) }
                        .disabled(cover == nil)
                    Button("Choose Cover…", action: chooseCover)
                    if let release, !release.isManual {
                        Button(release.hasArtwork ? "Cover Art Archive…" : "Other Releases' Cover Art…") {
                            archivePickerShown = true
                        }
                        Button("Use the Cover Art Archive's") { changeCover(to: nil) }
                        Button("Download Artwork…") {
                            Task { artworkOffer = await model.artworkOffer(for: release, rips: setRips) }
                        }
                    }
                    Divider()
                    Button("Export Cover…") {
                        CoverDrop.export(cover, name: coverFileName)
                    }
                    .disabled(cover == nil)
                }
                .help(
                    "Click to see the cover at full size. Drop an image here, or choose one from the menu (your own, or another of the Cover Art Archive's), to give every disc of the set this cover: in the rips, the album folder, and the files' tags."
                )
                .sheet(isPresented: $archivePickerShown) {
                    if let release {
                        CoverArtPickerSheet(release: release, disc: nil) { choice in
                            switch choice {
                            case .image(let image): changeCover(to: image)
                            case .release(let other, let front):
                                changeCover(to: front)
                                Task {
                                    let images = (try? await CoverArtClient().images(releaseID: other)) ?? []
                                    artworkOffer = ArtworkOffer(images: images, rips: setRips, afterCover: true)
                                }
                            case .discSleeves: model.useDiscSleeves(of: release)
                            }
                        }
                    }
                }
                .alert(
                    artworkOffer?.title ?? "",
                    isPresented: Binding(get: { artworkOffer != nil }, set: { if !$0 { artworkOffer = nil } }),
                    presenting: artworkOffer
                ) { offer in
                    Button("Save Artwork") { model.saveArtwork(offer.images, of: offer.rips) }
                    Button(offer.afterCover ? "Cover Only" : "Cancel", role: .cancel) {}
                } message: { offer in
                    Text(offer.message)
                }
                #if DEBUG
                    .onAppear { archivePickerShown = UserDefaults.standard.bool(forKey: "coverArchive") }
                #endif
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 16) {
                    field("Album", text: $album, prompt: release?.title ?? ripSet.title)
                    field("Album Artist", text: $albumArtist, prompt: release?.artist ?? ripSet.artist)
                    field("Date", text: $date, prompt: release?.date ?? "").frame(width: 140)
                }
                Text(
                    "The names are the set's: every disc takes them. A change is kept when you press Return or leave the field; Update the Library writes it into the encoded files."
                )
                .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Chip(
                        text: ripSet.isComplete
                            ? ripSet.summary
                            : "\(ripSet.discs.count) of \(ripSet.discCount) discs ripped",
                        tone: ripSet.isComplete ? .good : .neutral, systemImage: "square.stack")
                    if let release, let label = release.labels.compactMap(\.name).first { Chip(text: label) }
                    if let genre = release?.genre { Chip(text: genre, systemImage: "music.note.list") }
                    if !edits.isEmpty { Chip(text: "Edited", tone: .warning, systemImage: "pencil") }
                }
                // A complete set's chip says it all; an unfinished one's line gives the details.
                if !ripSet.isComplete { Text(ripSet.summary).font(.callout).foregroundStyle(.secondary) }
                if let replayGain {
                    Label(
                        "ReplayGain: " + replayGain.text.prefix(1).lowercased() + replayGain.text.dropFirst(),
                        systemImage: "speaker.wave.2"
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    .help(
                        "Each disc is measured when it is encoded. When the last disc of the set is encoded, every disc's files get the album gain over the whole set, so the set plays at one level."
                    )
                }
                let checking = ripSet.discs.values.filter { model.checking.contains($0.file) }.count
                if checking > 0 {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Looking \(Format.count(checking, "disc")) up in AccurateRip and CTDB again…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: label)
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
                titleIsPlaceholder: medium?.title == nil, seconds: tracks.isEmpty ? nil : seconds, disc: disc,
                report: report, children: tracks.isEmpty ? nil : tracks)
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
                if row.titleIsPlaceholder {
                    // Not a name from MusicBrainz or the user: the disc has none.
                    Text(row.title).italic().foregroundStyle(.secondary)
                        .help("MusicBrainz names no title for this disc")
                } else {
                    Text(row.title).foregroundStyle(row.number == nil || row.track != nil ? .primary : .secondary)
                }
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
        /// The title is Silverside's ("8 tracks"), as MusicBrainz names no title for the disc.
        var titleIsPlaceholder = false
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
        fieldsReleaseID = ripSet.releaseID
        album = edits.album ?? ""
        albumArtist = edits.albumArtist ?? ""
        date = edits.date ?? ""
    }

    private func saveFields() {
        // Fields typed for another set (the view shows a new one) are not this set's names.
        guard fieldsReleaseID == ripSet.releaseID else { return }
        func value(_ text: String, original: String?) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed == original ? nil : trimmed
        }
        var edits = self.edits
        let before = edits
        edits.album = value(album, original: release?.title)
        edits.albumArtist = value(MusicBrainzRelease.albumArtist(typed: albumArtist), original: release?.artist)
        edits.date = value(date, original: release?.date)
        guard edits != before else { return }
        do {
            try ReleaseEditsStore().remember(edits, forReleaseID: ripSet.releaseID)
            model.setNamesChanged()
            loadFields()
        } catch {
            model.alert = AppAlert(title: "The names could not be saved", message: "\(error)")
        }
    }

    private var coverFileName: String { "\(ripSet.artist) - \(ripSet.title) cover" }

    private func chooseCover() {
        let message =
            "Choose an image for the set's cover. JPEG and PNG are kept as they are; other formats become JPEG."
        if let data = CoverDrop.choose(message: message) { changeCover(to: CoverImage(data: data)) }
    }

    /// A cover for every disc: the encoded ones through a library update, the others through
    /// their rip folders; nil takes the Cover Art Archive's front cover.
    /// The set's rips, one for each disc ripped.
    private var setRips: [RecentRip] { ripSet.positions.compactMap(rip(at:)) }

    private func changeCover(to image: CoverImage?) {
        model.changeCover(ofSet: ripSet, rips: setRips, to: image)
    }
}
