import SilversideKit
import SwiftUI
import UniformTypeIdentifiers

/// An earlier rip: the headline, each track's result, and the report as text.
struct ResultsView: View {
    @Environment(AppModel.self) private var model
    var folder: URL
    var report: RipReport
    /// False for a report kept in the library after the rip's WAV files were deleted.
    var hasAudio = true
    /// The report file, for a report kept in the library; nil means the folder's disc.json.
    var reportFile: URL?
    @State private var reportShown = true
    @State private var hdcdDecodeShown = false
    /// The cover in the rip's folder, or in the album folder for a report kept in the library.
    @State private var cover: Data?
    @State private var coverTargeted = false
    /// The rip's own edits (track titles and artists), as typed; saved a moment after the last change.
    @State private var edits = MetadataEdits()
    @State private var savedEdits = MetadataEdits()
    /// The album edits kept for the release, which every disc of a set shares.
    @State private var keptEdits = MetadataEdits()
    /// Tracks whose artist field shows, though they have no artist of their own.
    @State private var artistRows: Set<Int> = []

    private var toc: TOC? { try? TOC(ctdbTOCString: report.toc) }

    /// The release with the names as they are now: the rip's edits, and the kept album edits.
    private var shownRelease: MusicBrainzRelease? {
        guard let toc, let release = report.release else { return report.release }
        return edits.merged(with: keptEdits).applied(to: release, toc: toc)
    }

    private func tracks(of release: MusicBrainzRelease?) -> [Int: MusicBrainzRelease.Track] {
        guard let toc, let release, let medium = release.medium(for: toc) else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(toc.audioTracks, medium.tracks).map { ($0.number, $1) })
    }

    private var titles: [Int: String] { tracks(of: shownRelease).mapValues(\.title) }

    /// Names can change while the rip has a release, and no library update for it is under way.
    private var canEditNames: Bool { report.release != nil && !model.updatingNames.contains(recentRip.file) }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(16)
                DiscGraph(tracks: DiscGraph.tracks(of: report))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                Divider()
                table
            }
            .frame(minWidth: 640)
            .layoutPriority(1)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Rip Report").font(.headline)
                    Spacer()
                    Button("Copy as Markdown") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.markdown, forType: .string)
                    }
                }
                .padding(12)
                Divider()
                HelpWebView(
                    html: MarkdownHTML.page(MarkdownHTML.render(Self.withoutTrackTable(report.markdown)), compact: true)
                )
            }
            .frame(minWidth: 300, idealWidth: 380, maxWidth: 560)
            .background(Color.secondary.opacity(0.04))
            .opacity(reportShown ? 1 : 0)
            .frame(width: reportShown ? nil : 0)
        }
        .task(id: "\(folder.path) \(model.coverVersion)") {
            cover =
                ["cover.jpg", "cover.png"].lazy.compactMap { try? Data(contentsOf: folder.appending(path: $0)) }
                .first
        }
        .onAppear {
            edits = MetadataEdits.read(fromReportAt: recentRip.file) ?? MetadataEdits()
            savedEdits = edits
            if let release = report.release, !release.isManual {
                keptEdits = ReleaseEditsStore().edits(forReleaseID: release.id) ?? MetadataEdits()
            }
        }
        // A name is saved, and the encoded files follow it, a moment after the last change.
        .task(id: edits) {
            guard edits != savedEdits else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            saveNames()
        }
        .onDisappear { saveNames() }
        .sheet(isPresented: $hdcdDecodeShown) { HDCDDecodeSheet(rip: recentRip) }
        #if DEBUG
            .onAppear { hdcdDecodeShown = canDecodeHDCD && UserDefaults.standard.bool(forKey: "hdcdDecode") }
        #endif
        .navigationTitle(shownRelease.map { "\($0.title)" } ?? folder.lastPathComponent)
        .navigationSubtitle(
            [shownRelease?.artist, report.drive.vendor + " " + report.drive.product].compactMap { $0 }.joined(
                separator: " · ")
        )
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if hasAudio && report.encoding == nil {
                    Button {
                        model.startLibraryRun(title: recentRip.title, encode: [recentRip], update: [])
                    } label: {
                        Label("Encode", systemImage: "music.note")
                    }
                    .help(encodeHelp)
                    .disabled(!report.isVerified || model.library?.isRunning == true)
                }
                if canDecodeHDCD {
                    Button {
                        hdcdDecodeShown = true
                    } label: {
                        Label("Decode HDCD…", systemImage: "waveform.badge.plus")
                    }
                    .help(
                        "Decode the HDCD codes: a copy beside the album, or in place of its files"
                    )
                    .disabled(model.library?.isRunning == true)
                }
                Button {
                    model.startRepair(RecentRip(folder: folder, report: report))
                } label: {
                    Label("Repair", systemImage: "bandage")
                }
                .help(repairHelp)
                .disabled(!canRepair)
                Button {
                    model.revealInFinder(folder)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                Toggle(isOn: $reportShown) {
                    Label("Rip Report", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the rip report")
                InfoButton(title: "Disc Info", help: "The release as MusicBrainz has it, and the disc's own codes") {
                    InfoSection.disc(report: report)
                }
            }
        }
    }

    /// A rip whose HDCD codes change the audio, not decoded yet, with lossless audio to decode:
    /// its WAV files, or the album's files.
    private var canDecodeHDCD: Bool {
        guard report.hdcd == .featuresUsed, report.encoding?.hdcdDecoded != true else { return false }
        return hasAudio || report.encoding?.format.isLossless == true
    }

    private var encodeHelp: String {
        if !report.isVerified { return "Only a verified rip is encoded. Repair it first, or rip the disc again." }
        return "Encode the rip into the library as \(model.settings.format.name), with the names as they are now."
    }

    /// Saves the edits, if they changed, and brings the encoded files up to date.
    private func saveNames() {
        guard edits != savedEdits else { return }
        savedEdits = edits
        model.saveNames(edits, of: recentRip)
    }

    private var canRepair: Bool {
        hasAudio && !report.isVerified && report.ctdb.status != .notInDatabase && model.repair?.isRunning != true
    }

    private var repairHelp: String {
        if !hasAudio { return "The rip was encoded and its WAV files deleted, so there is nothing to repair" }
        if report.isVerified { return "The rip is verified: there is nothing to repair" }
        if report.ctdb.status == .notInDatabase { return "CTDB does not have this disc, so it cannot repair the rip" }
        let others = model.earlierRips(of: report.toc).count - 1
        let drive = model.drives.first { $0.disc?.toc.ctdbTOCString == report.toc && !$0.isDemo }
        var text = "Check the rip against CTDB again, and repair it with CTDB's data"
        if others > 0 { text += ", pooled with \(Format.count(others, "other rip")) of this disc" }
        if let drive { text += ", with re-reads in \(drive.name)" }
        return text + "."
    }

    /// The report without its Tracks section: the table beside it shows the same, with room.
    static func withoutTrackTable(_ markdown: String) -> String {
        var kept = [String]()
        var skipping = false
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { skipping = line == "## Tracks" }
            if !skipping { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverView(data: cover, size: 112)
                .overlay {
                    if coverTargeted {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
                .onDrop(of: [.fileURL, .image], isTargeted: $coverTargeted) { providers in
                    guard let provider = providers.first else { return false }
                    CoverDrop.load(provider) { data in
                        if let data { model.changeCover(of: recentRip, to: CoverImage(data: data)) }
                    }
                    return true
                }
                .onTapGesture { chooseCover() }
                .onDrag { CoverDrop.provider(for: cover, name: coverFileName) ?? NSItemProvider() }
                .contextMenu {
                    Button("Choose Cover…") { chooseCover() }
                    if let release = report.release, !release.isManual, release.hasFrontCover {
                        Button("Use the Cover Art Archive's") { model.changeCover(of: recentRip, to: nil) }
                    }
                    Divider()
                    Button("Export Cover…") { CoverDrop.export(cover, name: coverFileName) }.disabled(cover == nil)
                }
                .help(
                    "Drop an image here, or click, to change the cover: in the rip, in the album folder, and in the encoded files' tags. Drag the cover out to save a copy."
                )
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(RipRun.headline(for: report)).font(.title2.weight(.semibold))
                } icon: {
                    Image(systemName: report.isVerified ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(report.isVerified ? Theme.good : Theme.warning)
                }
                .font(.title2)
                Text(
                    "Ripped \(report.date.formatted(date: .abbreviated, time: .shortened)) on \(report.drive.vendor) \(report.drive.product), read offset \(report.drive.readOffset.signedDescription), \(report.secure ? "secure" : "one read per track")."
                )
                .foregroundStyle(.secondary)
                ChipRow(chips: ResultChips.chips(for: report))
                if let advice = report.advice {
                    Text(advice).font(.callout).foregroundStyle(.secondary)
                }
                if model.updatingNames.contains(recentRip.file) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Writing the names into the encoded files…").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let set = model.set(for: report.release) {
                    Button(setText(set)) { model.selection = .set(set.releaseID) }
                        .buttonStyle(.link).font(.callout)
                        .help("The whole set: each disc's state, the album's names, and the work left")
                }
            }
        }
    }

    /// This rip, as the model's actions take it.
    private var recentRip: RecentRip {
        hasAudio
            ? RecentRip(folder: folder, report: report)
            : RecentRip(libraryReport: reportFile ?? folder.appending(path: "Rip Report.json"), report: report)
    }

    /// "Grateful Dead - Reckoning cover", for a cover dragged out or exported.
    private var coverFileName: String {
        NameTemplate.safeComponent(
            [report.release?.artist, report.release?.title].compactMap { $0 }.joined(separator: " - ") + " cover")
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an image for the cover. JPEG and PNG are kept as they are; other formats become JPEG."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = CoverDrop.imageData(from: url) { model.changeCover(of: recentRip, to: CoverImage(data: data)) }
    }

    /// "Disc 2 of 3 · Discs 1 and 2 of 3 ripped; disc 3 still to do".
    private func setText(_ set: RipSet) -> String {
        let position = report.discPosition.map { "Disc \($0) of \(set.discCount) · " } ?? ""
        return position + set.summary
    }

    /// The track's audio: the rip's WAV file, or the encoded file in the library.
    private func audioURL(of track: RipReport.Track) -> URL? {
        if hasAudio { return folder.appending(path: track.file) }
        guard let encoding = report.encoding, let file = encoding.file(ofTrack: track.number) else { return nil }
        return URL(filePath: encoding.folder, directoryHint: .isDirectory).appending(path: file)
    }

    /// The columns of the disc itself. A table takes ten columns at most, and the results need
    /// eleven, so these count as one.
    @TableColumnBuilder<RipReport.Track, Never> private var discColumns: some TableColumnContent<RipReport.Track, Never>
    {
        TableColumn("#") { track in Text(String(track.number)).foregroundStyle(.secondary) }.width(28)
        TableColumn("Title") { track in titleCell(track) }.width(min: 120, ideal: 180)
        TableColumn("Time") { track in Text(Format.duration(sectors: track.sectors)).foregroundStyle(.secondary) }
            .width(52)
        TableColumn("") { track in
            InfoButton(help: "Track info, and the tags of its encoded file") {
                InfoSection.track(track, report: report, title: titles[track.number], file: audioURL(of: track))
            }
        }
        .width(22)
    }

    /// A track's title, and its artist when it has one of its own, editable as in a drive's table.
    @ViewBuilder private func titleCell(_ track: RipReport.Track) -> some View {
        let shown = tracks(of: shownRelease)[track.number]
        let ownArtist = shown.flatMap { $0.artist != shownRelease?.artist ? $0.artist : nil }
        VStack(alignment: .leading, spacing: 1) {
            if canEditNames, shown != nil {
                TextField("", text: title(of: track.number)).textFieldStyle(.plain)
                if ownArtist != nil || artistRows.contains(track.number) {
                    TextField("", text: artist(of: track.number), prompt: Text("Track artist"))
                        .textFieldStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(titles[track.number] ?? track.file)
                if let ownArtist { Text(ownArtist).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .contextMenu {
            if canEditNames, shown != nil {
                if ownArtist == nil && !artistRows.contains(track.number) {
                    Button("Add Track Artist") { artistRows.insert(track.number) }
                }
                Button("Clear This Track's Edits") {
                    edits.setTitle(nil, ofTrack: track.number)
                    edits.setArtist(nil, ofTrack: track.number)
                    artistRows.remove(track.number)
                }
                .disabled(edits.tracks[track.number] == nil)
            }
        }
    }

    /// A binding to a track's title edit: MusicBrainz's title, or an empty one, clears the edit.
    private func title(of number: Int) -> Binding<String> {
        Binding(
            get: { titles[number] ?? "" },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                let original = tracks(of: report.release)[number]?.title
                edits.setTitle(trimmed.isEmpty || trimmed == original ? nil : trimmed, ofTrack: number)
            })
    }

    /// A binding to a track's artist edit: the release's own artist for the track, or none, clears the edit.
    private func artist(of number: Int) -> Binding<String> {
        Binding(
            get: { edits.tracks[number]?.artist ?? tracks(of: shownRelease)[number]?.artist ?? "" },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                let original = tracks(of: report.release)[number]?.artist
                edits.setArtist(trimmed.isEmpty || trimmed == original ? nil : trimmed, ofTrack: number)
            })
    }

    private var table: some View {
        Table(report.tracks) {
            TableColumn("") { track in
                if let url = audioURL(of: track) {
                    PlayButton(player: model.player, source: .file(url)) {
                        model.player.play(
                            file: url, title: titles[track.number] ?? track.file,
                            subtitle: report.release?.artist ?? folder.lastPathComponent)
                    }
                }
            }
            .width(22)
            discColumns
            TableColumn("Status") { track in FinishedStatus(track: track, ctdb: report.ctdb) }.width(
                min: 100, ideal: 115)
            TableColumn("Re-reads") { track in RereadsCell(track: track, ctdb: report.ctdb) }.width(min: 60, ideal: 75)
            TableColumn("Repaired") { track in RepairedCell(track: track) }.width(min: 60, ideal: 80)
            TableColumn("AccurateRip") { track in AccurateRipCell(state: .finished(track)) }.width(min: 100, ideal: 130)
            TableColumn("CTDB") { track in
                if let confidence = track.ctdbConfidence, confidence > 0 {
                    Text("Verified · \(confidence)").foregroundStyle(Theme.good)
                } else {
                    switch report.ctdb.status {
                    case .verified, .repaired: Text("Verified").foregroundStyle(Theme.good)
                    case .partlyRepaired, .notVerified: Text("Not verified").foregroundStyle(Theme.bad)
                    case .notInDatabase: Text("Not in database").foregroundStyle(.secondary)
                    case .notChecked: Text("Not checked").foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 80, ideal: 100)
            if let encoding = report.encoding {
                TableColumn("Encoding") { track in
                    if let file = encoding.file(ofTrack: track.number) {
                        Label(encoding.format.rawValue.uppercased(), systemImage: "checkmark.circle")
                            .foregroundStyle(Theme.good)
                            .help(file)
                    } else {
                        Text("Not encoded").foregroundStyle(.secondary)
                    }
                }
                .width(min: 60, ideal: 75)
            }
        }
        .alternatingRowBackgrounds(.disabled)
    }
}
