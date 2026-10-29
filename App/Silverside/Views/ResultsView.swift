import QuickLook
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
    /// The report is extra detail, so it is hidden at first, and stays as the person leaves it.
    @AppStorage("reportShown") private var reportShown = false
    @AppStorage("ripTrackColumns") private var columns = TableColumnCustomization<RipReport.Track>()
    @AppStorage("driveTrackColumns") private var driveColumns = TableColumnCustomization<DiscInfo.Track>()
    @State private var hdcdDecodeShown = false
    /// The cover in the rip's folder, or in the album folder for a report kept in the library.
    @State private var cover: Data?
    @State private var coverTargeted = false
    /// The cover's file while Quick Look shows it.
    @State private var coverPreview: URL?
    @State private var archivePickerShown = false
    /// The rip's own edits (track titles and artists), as typed; saved on Return, or when the
    /// focus leaves the field.
    @State private var edits = MetadataEdits()
    @State private var savedEdits = MetadataEdits()
    /// The album edits kept for the release, which every disc of a set shares.
    @State private var keptEdits = MetadataEdits()
    @State private var savedKeptEdits = MetadataEdits()
    /// The album's names as typed, kept when Return is pressed.
    @State private var albumText = ""
    @State private var albumArtistText = ""
    @State private var dateText = ""
    /// The name field being edited. Leaving one saves the names, as Return does.
    @FocusState private var focusedName: NameField?
    /// Tracks whose artist field shows, though they have no artist of their own.
    @State private var artistRows: Set<Int> = []

    private var toc: TOC? { try? TOC(ctdbTOCString: report.toc) }

    /// The chips for a disc that MusicBrainz did not know at the rip, with the names as they are now.
    private var addToMusicBrainzChip: [Chip] {
        guard let toc, report.release?.isManual == true, let release = shownRelease else { return [] }
        return [ResultChips.addToMusicBrainz(release, toc: toc), ResultChips.addDiscID(toc: toc)]
    }

    /// The chip for a release that MusicBrainz matched by its track lengths at the rip.
    private var lengthsMatchChip: [Chip] {
        guard let toc, report.release?.lacksDiscID(of: toc) == true else { return [] }
        return [ResultChips.lengthsMatch(toc: toc)]
    }

    /// The report, with the names as they are now, as the rip writes its Markdown.
    private var markdown: String {
        var shown = report
        if let shownRelease { shown.release = shownRelease }
        return shown.markdown
    }

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
                        NSPasteboard.general.setString(markdown, forType: .string)
                    }
                }
                .padding(12)
                Divider()
                HelpWebView(
                    html: MarkdownHTML.page(MarkdownHTML.render(Self.withoutTrackTable(markdown)), compact: true)
                )
            }
            .frame(minWidth: 300, idealWidth: 380, maxWidth: 560)
            .background(Color.secondary.opacity(0.04))
            .opacity(reportShown ? 1 : 0)
            .frame(width: reportShown ? nil : 0)
        }
        .task(id: "\(folder.path) \(model.coverVersion)") {
            // The disc's own sleeve, in a box set whose discs have theirs, else the album's cover.
            cover = CoverFiles.embedded(forDisc: report.discPosition, in: folder).flatMap { try? Data(contentsOf: $0) }
        }
        .onAppear {
            edits = MetadataEdits.read(fromReportAt: recentRip.file) ?? MetadataEdits()
            savedEdits = edits
            if let release = report.release, !release.isManual {
                keptEdits = ReleaseEditsStore().edits(forReleaseID: release.id) ?? MetadataEdits()
                savedKeptEdits = keptEdits
            }
            loadAlbumFields()
        }
        // A name is saved, and the encoded files follow it, when Return is pressed or the field
        // is left, so that the files and the album folder are not renamed while it is half typed.
        .onSubmit { saveNames() }
        .onChange(of: focusedName) { left, _ in
            guard let left else { return }
            if left.isAlbumField { keepAlbumFields() }
            saveNames()
        }
        .onDisappear {
            keepAlbumFields()
            saveNames()
        }
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
                        if report.isVerified || report.accepted != nil {
                            model.startLibraryRun(title: recentRip.title, encode: [recentRip], update: [])
                        } else {
                            model.acceptAndEncode(recentRip)
                        }
                    } label: {
                        Label(
                            report.isVerified || report.accepted != nil ? "Encode" : "Encode…",
                            systemImage: "music.note")
                    }
                    .help(encodeHelp)
                    .disabled(model.library?.isRunning == true)
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
                if let number = missingDataTrack {
                    Button {
                        model.saveDataTrack(number, of: recentRip)
                    } label: {
                        Label("Save Data Track…", systemImage: "externaldrive.badge.plus")
                    }
                    .help(
                        model.freeDrive(with: recentRip).map {
                            "Read data track \(number) from the disc in \($0.name), into the rip and its album folder"
                        } ?? "Put the disc in a drive to read its data track \(number), which the rip did not save"
                    )
                    .disabled(model.freeDrive(with: recentRip) == nil || model.savingDataTrack[recentRip.file] != nil)
                }
                if recentRip.canCheckAgain {
                    Button {
                        model.checkAgain([recentRip])
                    } label: {
                        Label("Check Again", systemImage: "arrow.clockwise")
                    }
                    .help(
                        "Look the disc up in AccurateRip and CTDB again, for results that came since the rip, and check the rip's audio against them. The disc is not needed."
                    )
                    .disabled(model.checking.contains(recentRip.file))
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
                InfoButton(
                    title: "Disc Info", help: "The release as MusicBrainz has it, and the disc's own codes",
                    debugID: "disc"
                ) {
                    InfoSection.disc(report: report)
                }
            }
        }
    }

    /// The first data track of the disc that the rip did not save, for Save Data Track.
    private var missingDataTrack: Int? {
        guard let toc else { return nil }
        let saved = Set((report.dataTracks ?? []).map(\.number))
        return toc.tracks.first { $0.kind == .data && !saved.contains($0.number) }?.number
    }

    /// A rip whose HDCD codes change the audio, not decoded yet, with lossless audio to decode:
    /// its WAV files, or the album's files.
    private var canDecodeHDCD: Bool {
        guard report.hdcd == .featuresUsed, report.encoding?.hdcdDecoded != true else { return false }
        return hasAudio || report.encoding?.format.isLossless == true
    }

    private var encodeHelp: String {
        if !report.isVerified && report.accepted == nil {
            return "Encode the rip although it is not verified, once you accept it as-is: listen to its "
                + "unverified tracks first. Repair, or a rip in another drive, may still verify it."
        }
        return "Encode the rip into the library as \(model.settings.format.name), with the names as they are now."
    }

    /// Saves the edits, if they changed, and brings the encoded files up to date.
    /// Saves the rip's own edits, and the album's names kept for the release, then brings the
    /// encoded files up to date with them.
    private func saveNames() {
        guard edits != savedEdits || keptEdits != savedKeptEdits else { return }
        if keptEdits != savedKeptEdits, let release = report.release, !release.isManual {
            do {
                try ReleaseEditsStore().remember(keptEdits, forReleaseID: release.id)
            } catch {
                model.alert = AppAlert(title: "The names could not be saved", message: "\(error)")
                return
            }
        }
        savedEdits = edits
        savedKeptEdits = keptEdits
        model.saveNames(edits, of: recentRip)
    }

    private func loadAlbumFields() {
        let shown = shownRelease
        albumText = shown?.title ?? ""
        albumArtistText = shown?.artist ?? ""
        dateText = shown?.date ?? ""
    }

    /// Keeps the album's names as typed: the release's own value, or an empty one, clears the
    /// edit. A MusicBrainz release keeps them for the release, as the set view does, so that a
    /// later rip of the disc gets them too; a release Silverside made keeps them in the rip's
    /// own edits.
    private func keepAlbumFields() {
        guard let release = report.release else { return }
        func keep(_ text: String, _ field: WritableKeyPath<MetadataEdits, String?>, original: String?) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let value = trimmed.isEmpty || trimmed == original ? nil : trimmed
            if release.isManual {
                edits[keyPath: field] = value
            } else {
                keptEdits[keyPath: field] = value
                // The kept value is the only one, so clearing it shows MusicBrainz's again.
                edits[keyPath: field] = nil
            }
        }
        keep(albumText, \.album, original: release.title)
        keep(albumArtistText, \.albumArtist, original: release.artist)
        keep(dateText, \.date, original: release.date)
        loadAlbumFields()
    }

    /// The album, its artist, and its date, for a rip that is not one disc of a set: a set's
    /// names are edited in its own view.
    @ViewBuilder private var albumFields: some View {
        if let release = report.release, model.set(for: release) == nil {
            HStack(alignment: .top, spacing: 12) {
                EditableField(
                    label: "Album", text: $albumText, shown: shownRelease?.title ?? release.title,
                    editable: canEditNames, focus: $focusedName, field: .album)
                EditableField(
                    label: "Album Artist", text: $albumArtistText, shown: shownRelease?.artist ?? release.artist,
                    editable: canEditNames, focus: $focusedName, field: .albumArtist)
                EditableField(
                    label: "Date", text: $dateText, shown: shownRelease?.date ?? release.date ?? "",
                    editable: canEditNames, focus: $focusedName, field: .date
                )
                .frame(width: 140)
            }
            .onSubmit {
                keepAlbumFields()
                saveNames()
            }
        }
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
                .overlay(alignment: .bottomTrailing) {
                    CoverArchiveBadge(release: report.release) { archivePickerShown = true }
                }
                .overlay {
                    if coverTargeted {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
                .onDrop(of: [.fileURL, .image], isTargeted: $coverTargeted) { providers in
                    guard let provider = providers.first else { return false }
                    CoverDrop.load(provider) { model.changeCover(of: recentRip, to: CoverImage(data: $0)) }
                    return true
                }
                .onTapGesture {
                    if cover != nil {
                        coverPreview = CoverDrop.file(for: cover, name: coverFileName)
                    } else {
                        chooseCover()
                    }
                }
                .onDrag { CoverDrop.provider(for: cover, name: coverFileName) ?? NSItemProvider() }
                .quickLookPreview($coverPreview)
                .contextMenu {
                    Button("Quick Look") { coverPreview = CoverDrop.file(for: cover, name: coverFileName) }
                        .disabled(cover == nil)
                    Button("Choose Cover…") { chooseCover() }
                    if let release = report.release, release.hasArtwork {
                        Button("Cover Art Archive…") { archivePickerShown = true }
                    }
                    if let release = report.release, !release.isManual, release.hasFrontCover {
                        Button("Use the Cover Art Archive's") { model.changeCover(of: recentRip, to: nil) }
                    }
                    Divider()
                    Button("Export Cover…") { CoverDrop.export(cover, name: coverFileName) }.disabled(cover == nil)
                }
                .help(
                    "Click to see the cover at full size. Drop an image here, or choose one from the menu (your own, or another of the Cover Art Archive's), to change the cover: in the rip, in the album folder, and in the encoded files' tags. Drag the cover out to save a copy."
                )
                .sheet(isPresented: $archivePickerShown) {
                    if let release = report.release {
                        CoverArtPickerSheet(release: release, disc: report.discPosition) { choice in
                            switch choice {
                            case .image(let image): model.changeCover(of: recentRip, to: image)
                            case .discSleeves: model.useDiscSleeves(of: release)
                            }
                        }
                    }
                }
                #if DEBUG
                    .onAppear { archivePickerShown = UserDefaults.standard.bool(forKey: "coverArchive") }
                #endif
            VStack(alignment: .leading, spacing: 6) {
                albumFields.padding(.bottom, 6)
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
                ChipRow(chips: lengthsMatchChip + addToMusicBrainzChip + ResultChips.chips(for: report))
                if model.checking.contains(recentRip.file) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Looking the disc up in AccurateRip and CTDB again…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else if let result = model.checkResults[recentRip.file] {
                    Text("Checked again: \(result)").font(.callout).foregroundStyle(.secondary)
                } else if let checked = report.checkedAgain {
                    Text("Checked again \(checked.formatted(date: .abbreviated, time: .shortened)).")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let advice = report.advice {
                    Text(advice).font(.callout).foregroundStyle(.secondary)
                }
                if let fraction = model.savingDataTrack[recentRip.file] {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Saving the data track · \(Int(fraction * 100))%").font(.callout).foregroundStyle(
                            .secondary)
                    }
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
        let message = "Choose an image for the cover. JPEG and PNG are kept as they are; other formats become JPEG."
        if let data = CoverDrop.choose(message: message) {
            model.changeCover(of: recentRip, to: CoverImage(data: data))
        }
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

    /// The columns of the disc itself, as one: a table's builder takes ten at most.
    @TableColumnBuilder<RipReport.Track, Never> private var discColumns: some TableColumnContent<RipReport.Track, Never>
    {
        TableColumn("#") { track in Text(String(track.number)).foregroundStyle(.secondary) }.width(28)
            .customizationID("number").disabledCustomizationBehavior(.all)
        TableColumn("Title") { track in titleCell(track) }.width(min: 160, ideal: 360)
            .customizationID("title").disabledCustomizationBehavior(.visibility)
        TableColumn("Time") { track in Text(Format.duration(sectors: track.sectors)).foregroundStyle(.secondary) }
            .width(52)
            .customizationID("time").disabledCustomizationBehavior(.visibility)
        TableColumn("") { track in
            InfoButton(help: "Track info, and the tags of its encoded file", debugID: "track\(track.number)") {
                InfoSection.track(track, report: report, title: titles[track.number], file: audioURL(of: track))
            }
        }
        .width(22)
        .customizationID("info").disabledCustomizationBehavior(.all)
    }

    /// A track's title, and its artist when it has one of its own, editable as in a drive's table.
    @ViewBuilder private func titleCell(_ track: RipReport.Track) -> some View {
        let shown = tracks(of: shownRelease)[track.number]
        let ownArtist = shown.flatMap { $0.artist != shownRelease?.artist ? $0.artist : nil }
        VStack(alignment: .leading, spacing: 1) {
            if canEditNames, shown != nil {
                TextField("", text: title(of: track.number)).textFieldStyle(.plain)
                    .focused($focusedName, equals: .title(track.number))
                if ownArtist != nil || artistRows.contains(track.number) {
                    TextField("", text: artist(of: track.number), prompt: Text("Track artist"))
                        .textFieldStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        .focused($focusedName, equals: .artist(track.number))
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
        Table(report.tracks, columnCustomization: $columns) {
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
            .customizationID("play").disabledCustomizationBehavior(.all)
            discColumns
            TableColumn("Status") { track in
                FinishedStatus(
                    track: track, ctdb: report.ctdb,
                    showsRereads: columns[visibility: TrackColumns.rereads] != .visible)
            }
            .width(min: 110, ideal: 150)
            .customizationID("status").disabledCustomizationBehavior(.visibility)
            TableColumn("Re-reads") { track in RereadsCell(track: track, ctdb: report.ctdb) }.width(min: 60, ideal: 75)
                .customizationID(TrackColumns.rereads).defaultVisibility(.hidden)
            TableColumn("AccurateRip") { track in AccurateRipCell(state: .finished(track)) }.width(min: 90, ideal: 110)
                .customizationID("accurateRip")
            TableColumn("CTDB") { track in CTDBResultCell(track: track, ctdb: report.ctdb) }.width(min: 70, ideal: 90)
                .customizationID("ctdb")
            if let encoding = report.encoding {
                TableColumn("Encoding") { track in
                    if let file = encoding.file(ofTrack: track.number) {
                        CheckedText(text: encoding.format.rawValue.uppercased()).help(file)
                    } else {
                        Text("Not encoded").foregroundStyle(.secondary)
                    }
                }
                .width(min: 60, ideal: 75)
                .customizationID("encoding")
            }
        }
        .alternatingRowBackgrounds(.disabled)
        .onChange(of: columns) { TrackColumns.copyVisibility(from: columns, to: &driveColumns) }
    }
}
