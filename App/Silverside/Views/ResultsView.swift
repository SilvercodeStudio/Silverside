import QuickLook
import SilversideKit
import SwiftUI
import UniformTypeIdentifiers

/// The rip report as a page. SwiftUI compares the report before it builds the page again, so
/// typing a name in the track table does not render the Markdown at each keystroke.
private struct ReportPage: View, Equatable {
    var report: RipReport

    var body: some View {
        HelpWebView(
            html: MarkdownHTML.page(MarkdownHTML.render(ResultsView.withoutTrackTable(report.markdown)), compact: true))
    }
}

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
    @State private var dtsDecodeShown = false
    /// The cover in the rip's folder, or in the album folder for a report kept in the library.
    @State private var cover: Data?
    @State private var coverTargeted = false
    /// The cover's file while Quick Look shows it.
    @State private var coverPreview: URL?
    /// The other images in the Artwork folder, which Quick Look shows after the cover.
    @State private var artwork: [URL] = []
    /// What Quick Look shows: the cover's file, then the Artwork folder's images.
    @State private var previewItems: [URL] = []
    @State private var archivePickerShown = false
    /// A cover chosen for a disc of a set, while the question asks for which discs.
    @State private var setDiscCover: CoverImage?
    /// True if this disc of a set has a cover of its own (`CoverFiles.disc`).
    @State private var hasOwnCover = false
    /// The other images of a release, offered for the rip's Artwork folder.
    @State private var artworkOffer: ArtworkOffer?
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
        // A set of the user's own is not offered to MusicBrainz.
        if release.isCustomSet { return [ResultChips.addDiscID(toc: toc)] }
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

    /// The report with the names as last saved, for the report pane: the pane is built again
    /// when a name is saved, not at each keystroke.
    private var savedReport: RipReport {
        var shown = report
        if let toc, let release = report.release {
            shown.release = savedEdits.merged(with: savedKeptEdits).applied(to: release, toc: toc)
        }
        return shown
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

    /// Names can change while the rip has a release, and no update of its album names is under
    /// way: that update can move the album folder and the report with it. Track names can change
    /// during an update of track names, so Tab goes on to the next track.
    private var canEditNames: Bool { report.release != nil && !model.renamingAlbums.contains(recentRip.file) }

    /// The disc's logo, from the report. `-discLogo cdText` shows that one, for a screenshot.
    private var discLogo: DiscLogo? {
        #if DEBUG
            if let name = UserDefaults.standard.string(forKey: "discLogo"), let logo = DiscLogo(rawValue: name) {
                return logo
            }
        #endif
        return DiscLogo.logo(for: report)
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(16)
                DiscGraph(tracks: DiscGraph.tracks(of: report))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                Divider()
                // The disc's logo at the table's lower left, where the last tracks scroll out from under it.
                table
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if let logo = discLogo {
                            HStack {
                                DiscLogoView(logo: logo).discLogoBackdrop()
                                    .padding(.leading, 10).padding(.bottom, RipButton.inset - 4)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .background(ScrollersPastInset(table: true))
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
                ReportPage(report: savedReport).equatable()
            }
            .frame(minWidth: 300, idealWidth: 380, maxWidth: 560)
            .background(Color.secondary.opacity(0.04))
            .opacity(reportShown ? 1 : 0)
            .frame(width: reportShown ? nil : 0)
        }
        .confirmationDialog(
            "Use this cover for disc \(report.discPosition ?? 0) only, or for every disc of the set?",
            isPresented: Binding(get: { setDiscCover != nil }, set: { if !$0 { setDiscCover = nil } }),
            presenting: setDiscCover
        ) { image in
            Button("Disc \(report.discPosition ?? 0) Only") { model.changeDiscCover(of: recentRip, to: image) }
            Button("Every Disc") {
                if let set = setOfDisc {
                    model.changeCover(ofSet: set, rips: setRips(set), to: image)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(
                "A disc's own cover goes into its files in place of the set's, as for each volume of a box set. Every Disc gives all of them this cover, and takes away the discs' own."
            )
        }
        .task(id: "\(folder.path) \(model.coverVersion)") {
            // The disc's own sleeve, in a box set whose discs have theirs, else the album's cover.
            cover = CoverFiles.embedded(forDisc: report.discPosition, in: folder).flatMap { try? Data(contentsOf: $0) }
            hasOwnCover = CoverFiles.disc(report.discPosition, in: folder) != nil
            artwork = CoverFiles.artwork(in: ArtworkOffer.folders(of: [recentRip]))
            previewItems = (CoverDrop.file(for: cover, name: coverFileName).map { [$0] } ?? []) + artwork
        }
        .onAppear {
            edits = MetadataEdits.read(fromReportAt: recentRip.file) ?? MetadataEdits()
            savedEdits = edits
            if let release = report.release, release.sharesAlbumEdits {
                keptEdits =
                    ReleaseEditsStore().edits(forReleaseID: release.id, rip: RipIdentity(report: report))
                    ?? MetadataEdits()
                savedKeptEdits = keptEdits
            }
            loadAlbumFields()
        }
        // A name is saved, and the encoded files follow it, when it is accepted (Return, Tab,
        // or leaving the field: `NameTextField`), so that the files and the album folder are
        // not renamed while it is half typed.
        .onDisappear {
            keepAlbumFields()
            saveNames()
        }
        .sheet(isPresented: $hdcdDecodeShown) { HDCDDecodeSheet(rip: recentRip) }
        .sheet(isPresented: $dtsDecodeShown) { DTSDecodeSheet(rip: recentRip) }
        #if DEBUG
            .onAppear { hdcdDecodeShown = canDecodeHDCD && UserDefaults.standard.bool(forKey: "hdcdDecode") }
            .onAppear { dtsDecodeShown = canDecodeDTS && UserDefaults.standard.bool(forKey: "dtsDecode") }
            // `-playTrack 5` puts track 5 in the player bar, paused, for a screenshot of the bar.
            .onAppear {
                let number = UserDefaults.standard.integer(forKey: "playTrack")
                guard number > 0, let track = report.tracks.first(where: { $0.number == number }),
                    let url = audioURL(of: track)
                else { return }
                model.player.play(
                    file: url, title: titles[number] ?? track.file, subtitle: report.release?.artist ?? "",
                    holdsDTS: false)
                model.player.togglePause()
            }
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
                if canDecodeDTS {
                    Button {
                        dtsDecodeShown = true
                    } label: {
                        Label("Decode DTS…", systemImage: "hifispeaker.2")
                    }
                    .help(
                        "Decode the DTS stream into surround files with ffmpeg: a copy beside the album, or in place of its files"
                    )
                    .disabled(model.library?.isRunning == true)
                }
                if let number = missingDataTrack {
                    Button {
                        model.saveDataTrack(number, of: recentRip)
                    } label: {
                        Label("Save Data Track", systemImage: "externaldrive.badge.plus")
                    }
                    .help(
                        model.freeDrive(with: recentRip).map {
                            "Read data track \(number) from the disc in \($0.name), into the rip and its album folder"
                        } ?? "Put the disc in a drive to read its data track \(number), which the rip did not save"
                    )
                    .disabled(model.freeDrive(with: recentRip) == nil || model.savingDataTrack[recentRip.file] != nil)
                }
                if model.canMakeVideo(of: recentRip) {
                    if let fraction = model.makingVideo[recentRip.file] {
                        Label("Making Video · \(Int(fraction * 100))%", systemImage: "film")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.secondary)
                    } else {
                        Menu {
                            if CDGraphicsVideo.hasExtendedGraphics(report) {
                                Section("256 Colors (CD+EG)") { videoButtons(picture: .extended) }
                                Section("16 Colors, as a CD+G Player Shows It") { videoButtons(picture: .standard) }
                            } else {
                                videoButtons(picture: .extended)
                            }
                        } label: {
                            Label("Make Video", systemImage: "film")
                        }
                        .help(
                            "Make a video of the disc's CD+G graphics over its music, the whole disc in one file with a chapter for each track, in the album's folder"
                        )
                    }
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

    @ViewBuilder private func videoButtons(picture: CDGraphicsVideo.Picture) -> some View {
        Button("With Apple Lossless Audio") { model.makeVideo(of: recentRip, audio: .appleLossless, picture: picture) }
        Button("With AAC Audio (Smaller)") { model.makeVideo(of: recentRip, audio: .aac, picture: picture) }
    }

    /// The first data track of the disc that the rip did not save, for Save Data Track.
    private var missingDataTrack: Int? { model.missingDataTrack(of: recentRip) }

    /// A rip whose HDCD codes change the audio, not decoded yet, with lossless audio to decode:
    /// its WAV files, or the album's files.
    private var canDecodeHDCD: Bool {
        guard report.hdcd == .featuresUsed, report.encoding?.hdcdDecoded != true else { return false }
        return hasAudio || report.encoding?.format.isLossless == true
    }

    /// A rip whose tracks hold a DTS stream, not decoded yet, with lossless audio to decode:
    /// its WAV files, or the album's files.
    private var canDecodeDTS: Bool {
        guard report.dts == .stream, report.encoding?.dtsDecoded == nil else { return false }
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
        if keptEdits != savedKeptEdits, let release = report.release, release.sharesAlbumEdits {
            do {
                try ReleaseEditsStore().remember(
                    keptEdits, forReleaseID: release.id, from: RipIdentity(report: report))
            } catch {
                model.alert = AppAlert(title: "The names could not be saved", message: "\(error)")
                return
            }
        }
        func album(_ edits: MetadataEdits) -> MetadataEdits {
            var album = edits
            album.tracks = [:]
            return album
        }
        let renamesAlbum = album(edits) != album(savedEdits) || keptEdits != savedKeptEdits
        savedEdits = edits
        savedKeptEdits = keptEdits
        model.saveNames(edits, of: recentRip, renamesAlbum: renamesAlbum)
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
            if !release.sharesAlbumEdits {
                edits[keyPath: field] = value
            } else {
                keptEdits[keyPath: field] = value
                // The rip keeps the value too, for when a later rip of the same disc keeps
                // other names for the release; clearing both shows MusicBrainz's again.
                edits[keyPath: field] = value
            }
        }
        keep(albumText, \.album, original: release.title)
        keep(MusicBrainzRelease.albumArtist(typed: albumArtistText), \.albumArtist, original: release.artist)
        keep(dateText, \.date, original: release.date)
        loadAlbumFields()
    }

    /// The album, its artist, and its date, for a rip that is not one disc of a set: a set's
    /// names are edited in its own view.
    @ViewBuilder private var albumFields: some View {
        if let release = report.release, model.set(for: release) == nil {
            HStack(alignment: .top, spacing: 12) {
                EditableField(
                    label: "Album", text: accepting($albumText), shown: shownRelease?.title ?? release.title,
                    editable: canEditNames, focus: $focusedName, field: .album)
                EditableField(
                    label: "Album Artist", text: accepting($albumArtistText),
                    shown: shownRelease?.artist ?? release.artist,
                    editable: canEditNames, focus: $focusedName, field: .albumArtist,
                    isCompilation: shownRelease?.isCompilation == true)
                EditableField(
                    label: "Date", text: accepting($dateText), shown: shownRelease?.date ?? release.date ?? "",
                    editable: canEditNames, focus: $focusedName, field: .date
                )
                .frame(width: 140)
            }
        }
    }

    /// An album field's text, kept and saved when the field's text is accepted.
    private func accepting(_ text: Binding<String>) -> Binding<String> {
        Binding(
            get: { text.wrappedValue },
            set: { typed in
                text.wrappedValue = typed
                keepAlbumFields()
                saveNames()
            })
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
                .coverAccessibility(hasCover: cover != nil) {
                    coverPreview = CoverDrop.file(for: cover, name: coverFileName)
                } choose: {
                    chooseCover()
                }
                .overlay(alignment: .bottomTrailing) {
                    CoverArchiveBadge(release: report.release) { archivePickerShown = true }
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
                    CoverDrop.load(provider) { useCover(CoverImage(data: $0)) }
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
                .quickLookPreview($coverPreview, in: previewItems)
                .contextMenu { coverMenu }
                .help(
                    "Click to see the cover at full size. Drop an image here, or choose one from the menu (your own, or another of the Cover Art Archive's), to change the cover: in the rip, in the album folder, and in the encoded files' tags. On a disc of a set, it asks whether the cover is for this disc only (as for each volume of a box set) or for every disc. Drag the cover out to save a copy."
                )
                .sheet(isPresented: $archivePickerShown) {
                    if let release = report.release {
                        CoverArtPickerSheet(release: release, disc: report.discPosition) { choice in
                            switch choice {
                            case .image(let image?): useCover(image)
                            case .image(nil): useWholeSetCover(nil)
                            case .release(let other, let front):
                                useWholeSetCover(front)
                                Task {
                                    let images = (try? await CoverArtClient().images(releaseID: other)) ?? []
                                    artworkOffer = ArtworkOffer(images: images, rips: [recentRip], afterCover: true)
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
                if let notes = report.notes {
                    Button {
                        model.notesRip = model.allRips.first { $0.file == recentRip.file } ?? recentRip
                    } label: {
                        Label(notes, systemImage: "note.text").font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading).lineLimit(4)
                    }
                    .buttonStyle(.plain)
                    .help("Your notes on this rip. Click to edit them.")
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
                HStack(spacing: 14) {
                    if let set = model.set(for: report.release) {
                        Button(setText(set)) { model.selection = .set(set.releaseID) }
                            .help("The whole set: each disc's state, the album's names, and the work left")
                    }
                    if let release = report.release, release.isManual {
                        let rip = model.allRips.first { $0.file == recentRip.file } ?? recentRip
                        Button(release.isCustomSet ? "Change Set…" : "Part of a Set…") {
                            model.customSetTarget = .rip(rip)
                        }
                        .disabled(!model.canChangeRelease(rip))
                        .help(
                            "Put this disc in a set of your own with the other discs of its box, so that they become one album"
                        )
                    }
                    if report.release != nil {
                        // The model's rip knows whether its files are still there.
                        let rip = model.allRips.first { $0.file == recentRip.file } ?? recentRip
                        Button("Change Release…") { model.changingRelease = rip }
                            .disabled(!model.canChangeRelease(rip))
                            .help(
                                "Choose another release of this disc in MusicBrainz, such as the edition you have, and retag and rename the files to match"
                            )
                    }
                }
                .buttonStyle(.link).font(.callout)
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

    /// The cover's menu.
    @ViewBuilder private var coverMenu: some View {
        Button("Quick Look") { coverPreview = CoverDrop.file(for: cover, name: coverFileName) }
            .disabled(cover == nil)
        Button("Choose Cover…") { chooseCover() }
        if let release = report.release, !release.isManual {
            Button(release.hasArtwork ? "Cover Art Archive…" : "Other Releases' Cover Art…") {
                archivePickerShown = true
            }
        }
        if setOfDisc != nil, hasOwnCover {
            Button("Use the Set's Cover") { model.changeDiscCover(of: recentRip, to: nil) }
        }
        if let release = report.release, !release.isManual {
            Button("Use the Cover Art Archive's") { useWholeSetCover(nil) }
            Button("Download Artwork…") {
                Task { artworkOffer = await model.artworkOffer(for: release, rips: [recentRip]) }
            }
            .disabled(recentRip.isMissing)
        }
        Divider()
        Button("Export Cover…") { CoverDrop.export(cover, name: coverFileName) }.disabled(cover == nil)

    }

    private func chooseCover() {
        let message = "Choose an image for the cover. JPEG and PNG are kept as they are; other formats become JPEG."
        if let data = CoverDrop.choose(message: message) { useCover(CoverImage(data: data)) }
    }

    /// The set this rip is a disc of, if any: its cover changes ask which discs they are for.
    private var setOfDisc: RipSet? {
        report.discPosition == nil ? nil : model.set(for: report.release)
    }

    /// A new cover: for a disc of a set, after asking whether for this disc only or every disc.
    private func useCover(_ image: CoverImage) {
        if setOfDisc != nil {
            setDiscCover = image
        } else {
            model.changeCover(of: recentRip, to: image)
        }
    }

    /// The rips whose covers a change for the whole set updates: the newest rip of each disc,
    /// and this one, which may be an older rip of its disc.
    private func setRips(_ set: RipSet) -> [RecentRip] {
        let rips = model.rips(of: set)
        return rips.contains { $0.file == recentRip.file } ? rips : rips + [recentRip]
    }

    /// A cover for the whole album: for a disc of a set, every disc, and the discs that have
    /// covers of their own keep them. Nil takes the Cover Art Archive's front cover.
    private func useWholeSetCover(_ image: CoverImage?) {
        if let set = setOfDisc {
            model.changeCover(ofSet: set, rips: setRips(set), to: image, keepingDiscCovers: true)
        } else {
            model.changeCover(of: recentRip, to: image)
        }
    }

    /// "Disc 2 of 3 · disc 1 done; disc 3 still to do": the other discs, since the page is this one's.
    private func setText(_ set: RipSet) -> String {
        guard let position = report.discPosition else { return set.summary }
        let others = set.summary(besides: position)
        return "Disc \(position) of \(set.discCount)" + (others.isEmpty ? "" : " · " + others)
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
        TableColumn("Title") { track in titleCell(track) }.width(min: 120, ideal: 360)
            .customizationID("title").disabledCustomizationBehavior(.visibility)
        TableColumn("Time") { track in Text(Format.duration(sectors: track.sectors)).foregroundStyle(.secondary) }
            .width(52)
            .customizationID("time").disabledCustomizationBehavior(.visibility)
        TableColumn("") { track in
            if track.number > 0 {
                InfoButton(help: "Track info, and the tags of its encoded file", debugID: "track\(track.number)") {
                    InfoSection.track(track, report: report, title: titles[track.number], file: audioURL(of: track))
                }
            }
        }
        .width(22)
        .customizationID("info").disabledCustomizationBehavior(.all)
    }

    /// The track fields in Tab's order: those with a track to name.
    private var fieldOrder: [NameField] {
        let shown = tracks(of: shownRelease)
        return NameField.trackOrder(report.tracks.map(\.number).filter { shown[$0] != nil }) { number in
            shown[number].map { $0.artist != shownRelease?.artist } == true || artistRows.contains(number)
                || shownRelease?.isCompilation == true
        }
    }

    /// A track's title, and its artist when it has one of its own, editable as in a drive's table.
    @ViewBuilder private func titleCell(_ track: RipReport.Track) -> some View {
        if track.number == 0 {
            HiddenTrackTitle(title: title(ofTrack: 0) ?? track.file)
        } else {
            editableTitleCell(track)
        }
    }

    @ViewBuilder private func editableTitleCell(_ track: RipReport.Track) -> some View {
        let shown = tracks(of: shownRelease)[track.number]
        let ownArtist = shown.flatMap { $0.artist != shownRelease?.artist ? $0.artist : nil }
        VStack(alignment: .leading, spacing: 1) {
            if canEditNames, shown != nil {
                let title = title(of: track.number)
                NameTextField(
                    value: title.wrappedValue, field: .title(track.number), focus: $focusedName,
                    tabOrder: { fieldOrder }
                ) {
                    title.wrappedValue = $0
                    saveNames()
                }
                if ownArtist != nil || artistRows.contains(track.number) || shownRelease?.isCompilation == true {
                    let artist = artist(of: track.number)
                    NameTextField(
                        value: artist.wrappedValue, prompt: "Track artist", field: .artist(track.number),
                        focus: $focusedName, tabOrder: { fieldOrder }
                    ) {
                        artist.wrappedValue = $0
                        saveNames()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(titles[track.number] ?? track.file)
                if let ownArtist { Text(ownArtist).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .contextMenu {
            if canEditNames, shown != nil {
                if ownArtist == nil && !artistRows.contains(track.number) && shownRelease?.isCompilation != true {
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

    /// The report's tracks, after the hidden track before track 1 (track 0) if the rip kept one.
    private var rows: [RipReport.Track] { (report.hiddenTrack.map { [$0.reportTrack] } ?? []) + report.tracks }

    /// A track's title: the hidden track's from the release's pregap track.
    private func title(ofTrack number: Int) -> String? {
        guard number == 0 else { return titles[number] }
        return toc.flatMap { shownRelease?.medium(for: $0)?.hiddenTrack?.title } ?? "Hidden track"
    }

    private var table: some View {
        Table(rows, columnCustomization: $columns) {
            TableColumn("") { track in
                if let url = audioURL(of: track) {
                    PlayButton(player: model.player, source: .file(url)) {
                        // The rip's file, or the album's as the disc has it, holds the stream the rip found.
                        model.player.play(
                            file: url, title: title(ofTrack: track.number) ?? track.file,
                            subtitle: report.release?.artist ?? folder.lastPathComponent,
                            holdsDTS: track.dts == true && (hasAudio || report.encoding?.dtsDecoded == nil))
                    }
                }
            }
            .width(22)
            .customizationID("play").disabledCustomizationBehavior(.all)
            discColumns
            TableColumn("Status") { track in
                if track.number == 0, let hidden = report.hiddenTrack {
                    HiddenTrackVerdict(hidden: hidden)
                } else {
                    FinishedStatus(
                        track: track, ctdb: report.ctdb,
                        showsRereads: columns[visibility: TrackColumns.rereads] != .visible)
                }
            }
            .width(min: 100, ideal: 150, max: 265)
            .customizationID("status").disabledCustomizationBehavior(.visibility)
            TableColumn("Re-reads") { track in RereadsCell(track: track, ctdb: report.ctdb) }
                .width(min: 60, ideal: 75, max: 120)
                .customizationID(TrackColumns.rereads).defaultVisibility(.hidden)
            TableColumn("AccurateRip") { track in
                if track.number == 0 { HiddenTrackStatus.notCovered } else { AccurateRipCell(state: .finished(track)) }
            }
            .width(min: 70, ideal: 110, max: 165)
            .customizationID("accurateRip")
            TableColumn("CTDB") { track in
                if track.number == 0 {
                    HiddenTrackStatus.notCovered
                } else {
                    CTDBResultCell(track: track, ctdb: report.ctdb)
                }
            }
            .width(min: 60, ideal: 90, max: 160)
            .customizationID("ctdb")
            if let encoding = report.encoding {
                TableColumn("Encoding") { track in
                    if let file = encoding.file(ofTrack: track.number) {
                        CheckedText(
                            text: encoding.format.rawValue.uppercased(),
                            spoken: "Encoded as \(encoding.format.rawValue.uppercased())"
                        )
                        .help(file)
                    } else if encoding.silentTracksLeftOut?.contains(track.number) == true {
                        Text("Left out").foregroundStyle(.secondary)
                            .help("Digital silence: the album has no file for it. A disc image keeps it.")
                    } else {
                        Text("Not encoded").foregroundStyle(.secondary)
                    }
                }
                .width(min: 60, ideal: 75, max: 145)
                .customizationID("encoding")
            }
        }
        .alternatingRowBackgrounds(.disabled)
        .onChange(of: columns) { TrackColumns.copyVisibility(from: columns, to: &driveColumns) }
        .onDisappear(perform: TrackColumns.forgetWidths)
    }
}
