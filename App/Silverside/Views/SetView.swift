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
    @State private var archivePickerShown = false
    @State private var album = ""
    @State private var albumArtist = ""
    @State private var date = ""
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
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverView(data: cover)
                .overlay(alignment: .bottomTrailing) {
                    CoverArchiveBadge(release: release) { archivePickerShown = true }
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
                .quickLookPreview($coverPreview)
                .contextMenu {
                    Button("Quick Look") { coverPreview = CoverDrop.file(for: cover, name: coverFileName) }
                        .disabled(cover == nil)
                    Button("Choose Cover…", action: chooseCover)
                    if release?.hasArtwork == true {
                        Button("Cover Art Archive…") { archivePickerShown = true }
                    }
                    if release?.hasFrontCover == true {
                        Button("Use the Cover Art Archive's") { changeCover(to: nil) }
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
                            case .discSleeves: model.useDiscSleeves(of: release)
                            }
                        }
                    }
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
        edits.albumArtist = value(MusicBrainzRelease.albumArtist(typed: albumArtist), original: release?.artist)
        edits.date = value(date, original: release?.date)
        do {
            try ReleaseEditsStore().remember(edits, forReleaseID: ripSet.releaseID)
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
    private func changeCover(to image: CoverImage?) {
        let rips = ripSet.positions.compactMap(rip(at:))
        model.changeCover(ofSet: ripSet, rips: rips, to: image)
    }
}
