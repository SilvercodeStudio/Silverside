import QuickLook
import SilversideDarwin
import SilversideKit
import SwiftUI
import UniformTypeIdentifiers

/// A drive's disc: the album, the tracks, and the rip's progress, with the toolbar.
struct DriveDetailView: View {
    @Environment(AppModel.self) private var model
    @Bindable var slot: DriveSlot
    @State private var releasePickerShown = false
    @State private var optionsShown = false

    var body: some View {
        Group {
            switch slot.discState {
            case .empty:
                NoDiscView(driveName: slot.name, otherDisc: slot.device.otherDisc)
            case .reading:
                ProgressView("Reading the disc…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("The disc could not be read", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { slot.readDisc(settings: model.settings) }
                }
            case .ready:
                if let disc = slot.disc, disc.toc.audioTracks.isEmpty {
                    // A CD-ROM, such as a game or a program: nothing for a music ripper.
                    ContentUnavailableView {
                        Label("A data disc", systemImage: "externaldrive")
                    } description: {
                        Text(
                            "This disc holds only data, such as a computer program, and no audio tracks. Silverside rips audio CDs."
                        )
                    }
                } else if slot.disc != nil {
                    DiscView(slot: slot, releasePickerShown: $releasePickerShown)
                }
            }
        }
        .navigationTitle(slot.disc?.title ?? slot.name)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .sheet(isPresented: $releasePickerShown) {
            if let disc = slot.disc {
                ReleasePickerSheet(disc: disc) { release in slot.choose(release) }
            }
        }
        #if DEBUG
            // `-ripOptions 1` opens the options popover at launch, for screenshots; `-coverFile
            // /path.jpg` gives the disc a cover, as a drop would.
            .onAppear {
                if UserDefaults.standard.bool(forKey: "ripOptions") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { optionsShown = true }
                }
                if let path = UserDefaults.standard.string(forKey: "coverFile"), !path.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        if let data = CoverDrop.imageData(from: URL(filePath: path)) {
                            slot.disc?.userCover = CoverImage(data: data)
                        }
                    }
                }
            }
        #endif
    }

    private var subtitle: String {
        guard let disc = slot.disc else { return "" }
        return [disc.artist, slot.name].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var isRipping: Bool { slot.rip?.isRunning == true }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.eject(slot)
            } label: {
                Label("Eject", systemImage: "eject").padding(.horizontal, 4)
            }
            .help("Eject the disc (may take a few seconds)")
            .disabled((slot.device.discBSDName ?? slot.device.otherDiscBSDName) == nil || isRipping)

            Button {
                slot.lookUpAgain()
            } label: {
                Label("Look Up Metadata", systemImage: "arrow.triangle.2.circlepath").padding(.horizontal, 4)
            }
            .help("Ask MusicBrainz about this disc again")
            .disabled(slot.disc == nil || isRipping)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                optionsShown.toggle()
            } label: {
                Label("Options", systemImage: "slider.horizontal.3").padding(.horizontal, 4)
            }
            .help("Choices for the next rip: its folder, earlier rips to pool, offline")
            .disabled(slot.disc == nil || isRipping)
            .popover(isPresented: $optionsShown, arrowEdge: .bottom) {
                RipOptionsView(slot: slot)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("Mode", selection: $slot.fastMode) {
                Text("Secure").tag(false)
                Text("Fast (one read)").tag(true)
            }
            .help(
                "Secure re-reads tracks that do not match AccurateRip. Fast reads each track once. Normally, secure is recommended."
            )
            .disabled(isRipping)
            .padding(.leading, 10)
        }
        // Stop takes the Rip button's place during a rip: a disabled prominent button keeps its
        // blue fill with dim text, which reads as broken.
        if isRipping {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.stopRip(slot)
                } label: {
                    Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon).padding(.horizontal, 6)
                }
                .help("Stop after the read under way. The tracks ripped so far stay.")
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.startRip(slot)
                } label: {
                    Label(ripTitle, systemImage: "arrow.down.circle.fill").labelStyle(.titleAndIcon)
                        .padding(.trailing, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(canRip ? Color.accentColor : Color.gray)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!canRip)
            }
        }
    }

    private var canRip: Bool { slot.disc != nil && !slot.isBusy && !slot.selectedTracks.isEmpty }

    private var ripTitle: String {
        guard let disc = slot.disc else { return "Rip" }
        return slot.selectedTracks.count == disc.toc.audioTracks.count ? "Rip Disc" : "Rip Selected"
    }
}

/// The album header, the track table, and the status bar.
struct DiscView: View {
    @Environment(AppModel.self) private var model
    @Bindable var slot: DriveSlot
    @Binding var releasePickerShown: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let disc = slot.disc {
                AlbumHeader(slot: slot, disc: disc, releasePickerShown: $releasePickerShown, source: $slot.namesSource)
                    .padding(16)
            }
            if let rip = slot.rip, !rip.isRunning, let report = rip.report {
                ResultBanner(rip: rip, report: report, folder: rip.folder)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            Divider()
            // The Rip button floats over the table's lower right. As a safe area inset (the
            // table does not take content margins), it lets the last tracks scroll out from under it.
            TrackTable(slot: slot)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    HStack(alignment: .bottom, spacing: 0) {
                        if let logo = slot.discLogo, DiscLogoPlace.atTableCorner {
                            DiscLogoView(logo: logo).discLogoBackdrop()
                                .padding(.leading, 10).padding(.bottom, RipButton.inset - 4)
                        }
                        Spacer(minLength: 0)
                        // The disc's logo beside the button: the Compact Disc logo centered
                        // on it, and the logos built on that one with their tops in line.
                        if let logo = slot.discLogo, !DiscLogoPlace.atTableCorner {
                            let top = (RipButton.size - DiscLogo.compactDiscHeight) / 2
                            // On glass, as at an earlier rip's table corner, so that the rows under it
                            // do not show through; the logo stays where it was, inside the glass's padding.
                            DiscLogoView(logo: logo).discLogoBackdrop()
                                .padding(
                                    .bottom,
                                    RipButton.inset - DiscLogo.backdropPadding
                                        + (logo.hangsFromTop
                                            ? RipButton.size - top - logo.height : (RipButton.size - logo.height) / 2)
                                )
                                .padding(.trailing, 6)
                        }
                        RipButton(slot: slot)
                            .padding([.top, .bottom, .leading], RipButton.inset)
                            .padding(.trailing, RipButton.trailingInset)
                    }
                }
                .background(ScrollersPastInset(table: slot.rip != nil))
            Divider()
            StatusBar(slot: slot)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }
}

struct AlbumHeader: View {
    @Environment(AppModel.self) private var model
    @Bindable var slot: DriveSlot
    var disc: DiscInfo
    @Binding var releasePickerShown: Bool
    @Binding var source: DiscInfo.Source

    private var editable: Bool { slot.rip?.isRunning != true && disc.baseRelease != nil && source == .musicBrainz }
    @State private var coverTargeted = false
    /// The cover's file while Quick Look shows it.
    @State private var coverPreview: URL?
    @State private var archivePickerShown = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverView(data: disc.shownCover)
                .overlay(alignment: .bottomTrailing) {
                    if slot.rip?.isRunning != true {
                        CoverArchiveBadge(release: disc.release) { archivePickerShown = true }
                    }
                }
                .overlay {
                    if coverTargeted {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
                .onDrop(of: [.fileURL, .image], isTargeted: $coverTargeted) { providers in
                    guard slot.rip?.isRunning != true, let provider = providers.first else { return false }
                    CoverDrop.load(provider) { slot.disc?.userCover = CoverImage(data: $0) }
                    return true
                }
                .onTapGesture {
                    if disc.shownCover != nil {
                        coverPreview = CoverDrop.file(for: disc.shownCover, name: coverFileName)
                    } else if slot.rip?.isRunning != true {
                        chooseCover()
                    }
                }
                .onDrag { CoverDrop.provider(for: disc.shownCover, name: coverFileName) ?? NSItemProvider() }
                .quickLookPreview($coverPreview)
                .contextMenu {
                    Button("Quick Look") { coverPreview = CoverDrop.file(for: disc.shownCover, name: coverFileName) }
                        .disabled(disc.shownCover == nil)
                    Button("Choose Cover…") { chooseCover() }.disabled(slot.rip?.isRunning == true)
                    if let release = disc.release, release.hasArtwork {
                        Button("Cover Art Archive…") { archivePickerShown = true }
                            .disabled(slot.rip?.isRunning == true)
                    }
                    if disc.userCover != nil || disc.keptCover != nil || disc.sleeve != nil {
                        Button(disc.cover == nil ? "Remove Cover" : "Use the Cover Art Archive's") {
                            useArchiveCover()
                        }
                        .disabled(slot.rip?.isRunning == true)
                    }
                    Divider()
                    Button("Export Cover…") { CoverDrop.export(disc.shownCover, name: coverFileName) }
                        .disabled(disc.shownCover == nil)
                }
                .help(
                    "Click to see the cover at full size. Drop an image here, or choose one from the menu (your own, or another of the Cover Art Archive's), to change the cover: it goes in the rip and the tags. Drag the cover out to save a copy."
                )
                .sheet(isPresented: $archivePickerShown) {
                    if let release = disc.release {
                        CoverArtPickerSheet(release: release, disc: disc.shownMedium?.position) { choice in
                            switch choice {
                            case .image(let image?): slot.disc?.userCover = image
                            case .image(nil): useArchiveCover()
                            case .discSleeves:
                                try? ReleaseCoverStore().useDiscSleeves(true, releaseID: release.id)
                                slot.disc?.userCover = nil
                                Task {
                                    var info = disc
                                    await info.loadSleeve()
                                    slot.disc?.sleeve = info.sleeve
                                }
                            }
                        }
                    }
                }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 16) {
                    EditableField(
                        label: "Album", text: field(\.album, original: disc.baseRelease?.title),
                        shown: disc.title(from: source), editable: editable, field: .album,
                        pending: slot.pendingNames)
                    EditableField(
                        label: disc.yearIsFirstRelease ? "First Release" : "Date",
                        text: field(\.date, original: disc.baseRelease?.date),
                        shown: disc.shownRelease?.date ?? disc.release?.releaseGroup?.firstReleaseDate ?? "—",
                        prompt: disc.yearIsFirstRelease ? disc.release?.releaseGroup?.firstReleaseDate : nil,
                        editable: editable, field: .date, pending: slot.pendingNames
                    )
                    .frame(width: 120)
                    .help(
                        disc.yearIsFirstRelease
                            ? "This edition has no date in MusicBrainz. The grey date is the release group's first release; type a date to tag the files with one."
                            : "")
                }
                HStack(alignment: .top, spacing: 16) {
                    EditableField(
                        label: "Album Artist", text: field(\.albumArtist, original: disc.baseRelease?.artist),
                        shown: disc.artist(from: source).isEmpty ? "—" : disc.artist(from: source), editable: editable,
                        field: .albumArtist, pending: slot.pendingNames,
                        isCompilation: disc.shownRelease?.isCompilation == true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Tracks").font(.caption).foregroundStyle(.secondary)
                        Text("\(disc.toc.audioTracks.count) · \(Format.duration(sectors: disc.totalSectors))")
                            .font(.title3)
                            .padding(.vertical, 4)
                    }
                    .frame(width: 120, alignment: .leading)
                }
                HStack(alignment: .top, spacing: 8) {
                    FlowLayout(spacing: 8) {
                        lookupChip
                        if let earlier = earlierRelease, let found = disc.release {
                            ResultChips.earlierRelease(
                                earlier.release, medium: earlier.medium, found: found, toc: disc.toc)
                        }
                        hdcdChip
                        dataTrackChip
                        if disc.userCover != nil || (disc.sleeve == nil && disc.keptCover != nil) {
                            Chip(text: "Your cover", tone: .warning, systemImage: "photo")
                                .help("The cover you gave is saved with the rip and embedded in the files.")
                        } else if disc.sleeve != nil {
                            Chip(text: "This disc's sleeve", systemImage: "photo.stack")
                                .help(
                                    "Each disc of this set takes its own sleeve from the Cover Art Archive: this one's files embed it, and the album folder keeps the set's cover."
                                )
                        }
                        if !disc.edits.isEmpty {
                            Chip(text: "Edited", tone: .warning, systemImage: "pencil")
                                .help(
                                    "Names you changed. They go into the rip's tags and names, and the album's into the other discs of the set."
                                )
                        }
                        if let label = disc.labelText { Chip(text: label) }
                        if let genre = disc.shownRelease?.genre {
                            Chip(text: genre, systemImage: "music.note.list")
                                .help("The genre with the most votes in MusicBrainz. It goes into the files' tags.")
                        }
                        if let discLabel = disc.discLabel { Chip(text: discLabel, help: disc.discLabelHelp) }
                        earlierRipChip
                        earlierCopiesChip
                        if let set = model.set(for: disc.release) {
                            Button {
                                model.selection = .set(set.releaseID)
                            } label: {
                                Chip(
                                    text: "\(set.discs.count) of \(set.discCount) discs ripped",
                                    tone: set.isComplete ? .good : .neutral, systemImage: "square.stack")
                            }
                            .buttonStyle(.plain)
                            .help(set.summary + ". The album's names and cover are the set's. Click for the set.")
                        }
                        InfoButton(
                            help: "Disc info: the release as MusicBrainz has it, and the disc's own codes",
                            debugID: "disc"
                        ) {
                            InfoSection.disc(disc)
                        }
                        .keepsWithPrevious()
                        if let mcn = disc.mcn { Chip(text: "MCN \(mcn)") }
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 0)
                    if disc.hasCDText, disc.release != nil {
                        // The label goes above the picker when the chips leave no room beside it.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) {
                                namesFromLabel
                                namesFromPicker
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                namesFromLabel
                                namesFromPicker
                            }
                        }
                        .help(
                            "Show the names from MusicBrainz, or the CD-Text on the disc. The rip's tags come from MusicBrainz, unless you choose Use These Names."
                        )
                        if source == .cdText, let cdTextEdits {
                            Button("Use These Names") {
                                slot.disc?.edits = disc.edits.merged(with: cdTextEdits)
                                source = .musicBrainz
                            }
                            .fixedSize()
                            .disabled(slot.rip?.isRunning == true || cdTextEdits.isEmpty)
                            .help(
                                cdTextEdits.isEmpty
                                    ? "The CD-Text names are the same as MusicBrainz's."
                                    : "Tag the rip with the CD-Text names. They become your edits to the MusicBrainz names, so you can change them before the rip; Undo Edits goes back."
                            )
                        }
                    }
                    if !disc.edits.isEmpty, editable {
                        Button("Undo Edits") { slot.disc?.edits = MetadataEdits() }.fixedSize()
                    }
                    if disc.releases.count > 1 {
                        Button(
                            disc.isAmbiguous ? "Choose Release…" : "Other Releases (\(disc.releases.count - 1))…"
                        ) {
                            releasePickerShown = true
                        }
                        .fixedSize()
                    }
                }
                .padding(.top, 2)
                .task(id: copiesKey) { await model.findEarlierCopies(for: slot, stamp: copiesKey.stamp) }
            }
        }
    }

    /// What the earlier copies depend on: the folders, and the rip, which can leave tracks.
    private var copiesKey: CopiesKey {
        CopiesKey(
            folders: model.earlierCopyFolders(for: slot).all,
            stamp: slot.rip.map { "\($0.phase)" } ?? "", offline: slot.choices.offline)
    }

    private struct CopiesKey: Hashable {
        var folders: [URL]
        var stamp: String
        var offline: Bool
    }

    /// The tracks that earlier rips have accurate copies of, which the rip keeps: a stopped
    /// rip's, or another drive's. Not shown while a rip runs, or after one finishes.
    @ViewBuilder private var earlierCopiesChip: some View {
        let tracks = disc.toc.audioTracks.map(\.number)
        let kept =
            slot.earlierCopies.map { copies in
                tracks.filter { number in
                    copies.copies[number].map { slot.choices.poolsEarlierRips || copies.own.contains($0) } ?? false
                }
            } ?? []
        if !kept.isEmpty, !slot.choices.readsEveryTrack,
            slot.rip.map({ !$0.isRunning && $0.phase != .finished }) ?? true
        {
            let rest = tracks.filter { !kept.contains($0) }
            Chip(
                text: rest.isEmpty
                    ? "All \(tracks.count) tracks ripped before"
                    : "\(kept.count) of \(tracks.count) tracks ripped before",
                tone: .good, systemImage: "arrow.uturn.down.circle",
                help: "An earlier rip has copies of " + Self.tracks(kept)
                    + " that AccurateRip says are accurate. "
                    + (rest.isEmpty
                        ? "Rip keeps them all and reads no track again; it checks the whole disc with CTDB and writes the report. "
                        : "Rip keeps them and reads only \(Self.tracks(rest)), then checks the whole disc with CTDB. ")
                    + "To read every track again, turn on Read every track again in the rip options.")
        }
    }

    /// "track 3", "tracks 1–14", "tracks 1–4 and 9".
    private static func tracks(_ numbers: [Int]) -> String {
        (numbers.count == 1 ? "track " : "tracks ")
            + RipSet.list(RipReport.list(numbers).components(separatedBy: ", "))
            .replacingOccurrences(of: "-", with: "–")
    }

    /// A release of earlier rips with a disc of this disc's track lengths, which the lookup did
    /// not give: MusicBrainz has the disc ID on another release only.
    private var earlierRelease: (release: MusicBrainzRelease, medium: MusicBrainzRelease.Medium)? {
        guard case .found = disc.lookup, let release = disc.release, !release.isManual else { return nil }
        return ReleaseRanking.earlierRelease(
            fitting: disc.toc, found: disc.releases + [release], earlier: model.allRips.compactMap(\.report.release))
    }

    /// The edits that give the release the CD-Text's names.
    private var cdTextEdits: MetadataEdits? {
        guard let cdText = disc.cdText, let release = disc.baseRelease else { return nil }
        return MetadataEdits(cdText: cdText, release: release, medium: disc.medium, toc: disc.toc)
    }

    private var namesFromLabel: some View {
        Text("Names from").font(.callout).foregroundStyle(.secondary).fixedSize()
    }

    private var namesFromPicker: some View {
        Picker("Names from", selection: $source) {
            Text("MusicBrainz").tag(DiscInfo.Source.musicBrainz)
            Text("CD-Text").tag(DiscInfo.Source.cdText)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// "Grateful Dead - Cornell 5-8-77 cover", for a cover dragged out or exported.
    private var coverFileName: String {
        NameTemplate.safeComponent(
            [disc.artist, disc.title].filter { !$0.isEmpty }.joined(separator: " - ") + " cover")
    }

    /// Back to the Cover Art Archive's main front, for this disc and the release.
    private func useArchiveCover() {
        slot.disc?.userCover = nil
        slot.disc?.keptCover = nil
        slot.disc?.sleeve = nil
        guard let release = disc.release else { return }
        try? ReleaseCoverStore().forget(releaseID: release.id)
        // The download when the disc went in can have failed; then the cover comes now.
        if disc.cover == nil, release.hasFrontCover {
            Task {
                guard let data = await DiscInfo.frontCover(releaseID: release.id),
                    slot.disc?.release?.id == release.id
                else { return }
                slot.disc?.cover = data
            }
        }
    }

    private func chooseCover() {
        let message = "Choose an image for the cover. JPEG and PNG are kept as they are; other formats become JPEG."
        if let data = CoverDrop.choose(message: message) { slot.disc?.userCover = CoverImage(data: data) }
    }

    /// A binding to one album-level edit: the original value clears the edit.
    private func field(_ key: WritableKeyPath<MetadataEdits, String?>, original: String?) -> Binding<String> {
        Binding(
            get: { slot.disc?.edits[keyPath: key] ?? original ?? "" },
            set: { text in
                var trimmed = text.trimmingCharacters(in: .whitespaces)
                if key == \MetadataEdits.albumArtist { trimmed = MusicBrainzRelease.albumArtist(typed: trimmed) }
                slot.disc?.edits[keyPath: key] = trimmed.isEmpty || trimmed == original ? nil : trimmed
            })
    }

    /// HDCD, from the codes in the tracks ripped so far; before that, from MusicBrainz's format for the disc.
    /// A disc with a data track: an Enhanced CD's extras after the music, or a program's data first.
    @ViewBuilder private var dataTrackChip: some View {
        let data = disc.toc.tracks.filter { $0.kind == .data }
        if !data.isEmpty {
            let choice: String =
                switch model.settings.dataTracks {
                case .ask:
                    "The rip asks whether to save it. Saved, the album's folder gets a disc image of it (Data track.iso)"
                        + " and a Data track folder with the files on it, ready to open."
                case .save:
                    "The rip saves it: the album's folder gets a disc image of it (Data track.iso) and a Data track"
                        + " folder with the files on it, ready to open."
                case .skip: "The rip leaves it out (Settings › Ripping)."
                }
            let first = disc.toc.tracks.first?.kind == .data
            Chip(
                text: disc.toc.isEnhanced
                    ? "Enhanced CD · data track" : first ? "Mixed Mode CD · data track" : "Data track",
                systemImage: "externaldrive",
                help: (disc.toc.isEnhanced
                    ? "After the music, in a session of its own, this disc has a data track with extras for a computer. "
                    : first
                        ? "Track 1 of this disc is data for a computer (a Mixed Mode CD), so the music starts at track 2. "
                            + "Most CD players skip it. "
                        : "This disc has a data track for a computer. ") + choice)
        }
    }

    /// An earlier rip of this disc, in the rips folder or the library: the newest verified one,
    /// else the newest. A click opens it. Not shown once this drive has ripped the disc.
    @ViewBuilder private var earlierRipChip: some View {
        let rips = model.recentRips.filter { $0.report.toc == disc.toc.ctdbTOCString }
        if slot.rip == nil, let rip = rips.first(where: \.isVerified) ?? rips.first {
            let date = rip.date.formatted(date: .abbreviated, time: .omitted)
            let place = "\(date) on \(rip.driveName), in the \(rip.location.lowercased())"
            Chip(
                text: rip.isVerified ? "Previously ripped (verified)" : "Previously ripped (not verified)",
                tone: rip.isVerified ? .good : .warning, systemImage: "clock.arrow.circlepath",
                help: rip.isVerified
                    ? "You have a verified rip of this disc, from \(place). Click to open it."
                    : "You have a rip of this disc that is not verified, from \(place). Click to open it: Repair "
                        + "there, with the disc in a drive, reads again only what it needs. A new rip pools with it.",
                action: { model.selection = .rip(rip.file) })
        }
    }

    @ViewBuilder private var hdcdChip: some View {
        let ripped = (slot.rip?.trackStates.values ?? [:].values).compactMap { state -> RipReport.Track? in
            if case .finished(let track) = state { track } else { nil }
        }
        if let chip = ResultChips.hdcd(ripped.sorted { $0.number < $1.number }) {
            chip
        } else if ripped.isEmpty, let features = slot.probe?.hdcdFeatures {
            // From the few seconds of the first tracks read as the disc went in (`DiscProbe`).
            Chip(
                text: features == "nothing" ? "codes only" : features, logo: "HDCD",
                help: "HDCD codes in the first tracks, from a few seconds of each read when the disc went in. "
                    + (features == "nothing"
                        ? "There they ask for no peak extend or gain adjustment, so an HDCD decoder would play "
                            + "the same audio. Any benefit of the HDCD mastering process is already in the audio. "
                        : "They ask for "
                            + features.replacingOccurrences(of: "gain", with: "a gain adjustment")
                            .replacingOccurrences(of: ", ", with: " and ")
                            + ", so an HDCD decoder would change the audio. ")
                    + "The rip reads every track, and says what the whole disc asks for.")
        } else if ripped.isEmpty, disc.shownMedium?.format?.uppercased() == "HDCD" {
            Chip(
                text: "per MusicBrainz", logo: "HDCD",
                help:
                    "MusicBrainz lists this disc as HDCD. The rip looks for HDCD codes in the audio, which is the real test: some discs with the logo have none, and some without it have them."
            )
        }
    }

    @ViewBuilder private var lookupChip: some View {
        switch disc.lookup {
        case .notLookedUp:
            Chip(text: "MusicBrainz · not looked up", systemImage: "minus")
        case .lookingUp:
            Chip(text: "MusicBrainz · looking up…", isWorking: true)
        case .found where disc.isAmbiguous:
            Chip(
                text: "MusicBrainz · several releases match", tone: .warning, systemImage: "questionmark",
                help: "Several releases in MusicBrainz have this disc. Click to choose the one you have.",
                action: { releasePickerShown = true })
        case .found where disc.isFuzzy:
            ResultChips.lengthsMatch(toc: disc.toc)
        case .found:
            Chip(
                text: "MusicBrainz · Disc ID match", tone: .good, systemImage: "checkmark",
                help: disc.release.map(ResultChips.discIDMatchHelp) ?? "", link: disc.release?.pageURL)
        case .notFound:
            Chip(
                text: disc.namesFromEarlierRip
                    ? "Not in MusicBrainz · names from your earlier rip"
                    : disc.hasCDText
                        ? "Not in MusicBrainz · names from CD-Text" : "Not in MusicBrainz · type the names",
                tone: .warning, systemImage: "xmark"
            )
            .help(
                (disc.namesFromEarlierRip
                    ? "The names and the cover are those you gave your newest rip of this disc. " : "")
                    + "The files get no MusicBrainz IDs. Edit the names here; they are kept with the rip.")
            if let release = disc.shownRelease { ResultChips.addToMusicBrainz(release, toc: disc.toc) }
            ResultChips.addDiscID(toc: disc.toc)
        case .failed(let error):
            Chip(
                text: "MusicBrainz · lookup failed", tone: .bad, systemImage: "wifi.slash",
                help: "MusicBrainz did not answer, twice (\(error)). This is often brief: wait a moment, then "
                    + "click to look up again (or use Look Up Metadata).",
                action: slot.rip?.isRunning == true ? nil : { slot.lookUpAgain() })
        }
    }
}

/// A name field: the album's, or a track's, for its focus and for Tab.
enum NameField: Hashable {
    case album, albumArtist, date
    case title(Int)
    case artist(Int)

    /// The track fields in the order Tab goes through them: each track's title, then its
    /// artist where that field shows.
    static func trackOrder(_ numbers: [Int], showsArtist: (Int) -> Bool) -> [NameField] {
        numbers.flatMap { [.title($0)] + (showsArtist($0) ? [.artist($0)] : []) }
    }

    /// The field that Tab (or Shift-Tab, `backward`) goes to from this one; nil past either end.
    func next(in order: [NameField], backward: Bool) -> NameField? {
        guard let index = order.firstIndex(of: self) else { return nil }
        let next = backward ? index - 1 : index + 1
        return order.indices.contains(next) ? order[next] : nil
    }
}

/// Names typed and not yet accepted, by field, each with what accepting it does: so that a rip
/// that starts while a field is still being typed in gets its text.
final class PendingNames {
    private var accepts: [NameField: () -> Void] = [:]

    func set(_ field: NameField, accept: (() -> Void)?) { accepts[field] = accept }

    /// Accepts every name still being typed.
    func acceptAll() {
        let all = accepts.values
        accepts = [:]
        for accept in all { accept() }
    }
}

/// A text field for a name that changes nothing else while it is typed. The text stays in the
/// field until it is accepted, with Return, Tab, or by leaving the field; then `commit` gets it,
/// and the window redraws from it. A change for each key redrew the whole drive page and its
/// table, which made typing slow and could lose a key. `pending` keeps the text as typed.
struct NameTextField: View {
    var value: String
    var prompt: String?
    var field: NameField
    var focus: FocusState<NameField?>.Binding
    /// The track fields in Tab's order, for a field in a track table.
    var tabOrder: (() -> [NameField])?
    var pending: PendingNames?
    var commit: (String) -> Void
    /// The text as typed; nil shows `value`. It stays after it is accepted, until `value`
    /// changes with it: cleared at once, the field showed the old value for a moment, and the
    /// field, as it ended editing, wrote that old value back as if it were typed.
    @State private var draft: String?
    /// The draft was accepted, and waits for `value` to follow.
    @State private var isAccepted = false

    var body: some View {
        let text = Binding(
            get: { draft ?? value },
            set: { typed in
                guard typed != (draft ?? value) else { return }
                draft = typed
                isAccepted = false
                pending?.set(field) { commit(typed) }
            })
        TextField("", text: text, prompt: prompt.map { Text($0) })
            .textFieldStyle(.plain)
            .focused(focus, equals: field)
            .onSubmit(accept)
            .onChange(of: focus.wrappedValue) { left, now in
                if left == field, now != field { accept() }
            }
            .onChange(of: value) {
                // The accepted name arrived, or the name changed elsewhere (Undo Edits).
                if isAccepted || draft == nil {
                    draft = nil
                    isAccepted = false
                }
            }
            .onDisappear(perform: accept)
            .modifier(TabsThroughTracks(field: field, order: tabOrder, focus: focus, accept: accept))
    }

    private func accept() {
        guard let typed = draft, !isAccepted else { return }
        pending?.set(field, accept: nil)
        if typed == value {
            draft = nil
        } else {
            isAccepted = true
            commit(typed)
        }
    }
}

/// Tab and Shift-Tab go from one track field to the next, as in a spreadsheet. A table's
/// rows are not in the window's key view loop, so Tab would leave the table for the sidebar.
private struct TabsThroughTracks: ViewModifier {
    var field: NameField
    var order: (() -> [NameField])?
    var focus: FocusState<NameField?>.Binding
    /// Accepts the field's text, before the focus moves: a click into a field does not always
    /// set the focus state, so its change cannot be counted on to accept it.
    var accept: () -> Void

    func body(content: Content) -> some View {
        if let order {
            content.onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")]) { press in
                let backward = press.modifiers.contains(.shift) || press.key == KeyEquivalent("\u{19}")
                guard let next = field.next(in: order(), backward: backward) else { return .ignored }
                accept()
                focus.wrappedValue = next
                return .handled
            }
        } else {
            content
        }
    }
}

/// A field the user can edit, laid out like `Field`. `shown` is the text when it is not editable.
struct EditableField: View {
    var label: String
    @Binding var text: String
    var shown: String
    /// Grey text in an empty field, such as a date the release does not have itself.
    var prompt: String?
    var editable: Bool
    /// Where the field reports its focus, if anywhere.
    var focus: FocusState<NameField?>.Binding?
    var field = NameField.album
    /// Where the text waits while it is typed, for a rip that starts before it is accepted.
    var pending: PendingNames?
    /// True when the album artist is Various Artists: the field says that the album is a compilation.
    var isCompilation = false
    @FocusState private var ownFocus: NameField?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if editable {
                    NameTextField(
                        value: text, prompt: prompt, field: field, focus: focus ?? $ownFocus, pending: pending
                    ) { text = $0 }
                } else {
                    Text(shown).lineLimit(1)
                }
                if isCompilation { CompilationBadge() }
            }
            .font(.title3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(editable ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// "Compilation", in the album artist's field when it is Various Artists.
struct CompilationBadge: View {
    var body: some View {
        Label("Compilation", systemImage: "person.3.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .fixedSize()
            .help(
                "Various Artists, as MusicBrainz names it: the files are tagged as a compilation, the album goes in a "
                    + "Various Artists folder (or Settings › Naming › Compilations folder), and each track takes its own "
                    + "artist.")
    }
}

/// A labeled value, laid out as the design's fields.
struct Field: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.title3)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// The line under the table: what the rip is doing, how far it is, and the rip's settings.
struct StatusBar: View {
    @Environment(AppModel.self) private var model
    var slot: DriveSlot

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                // A spinner while something runs that the progress bar may not show moving.
                if isWorking {
                    ProgressView().controlSize(.small).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                }
                if let date = slot.ripOnInsertDate, slot.rip == nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Ripping in \(max(1, Int(date.timeIntervalSince(context.date).rounded(.up)))) s…")
                            .font(.callout.weight(.medium)).monospacedDigit()
                    }
                    Button("Rip Now") { model.ripNow(slot) }
                    Button("Cancel") { model.cancelRipOnInsert(slot) }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Text(statusText).font(.callout.weight(.medium)).lineLimit(1)
                    if let note = slot.ripOnInsertNote, slot.rip == nil {
                        Text("Not ripped at once: \(note).").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if slot.rip?.isRunning == true {
                    // Each second, for the time since the rip started, which moves when nothing else does.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in timeLabel }
                } else {
                    timeLabel
                }
                HStack(spacing: 10) {
                    Text(slot.fastMode ? "Fast" : "Secure")
                    if slot.choices.offline { Text("Offline") }
                    if slot.choices.poolsEarlierRips, !earlierRips.isEmpty {
                        Text("Pool \(earlierRips.count)").help("Earlier rips of this disc that join the rip")
                    }
                    if let folder = slot.choices.folder {
                        Text("Own folder").help("The rip goes in \(folder.path)")
                    }
                    if let offset = slot.rip?.readOffset { Text("Offset \(offset.signedDescription)") }
                    Text(model.settings.encodeAfterRip ? model.settings.format.rawValue.uppercased() : "WAV")
                    if slot.rip != nil {
                        Button("Show Log") { model.logShown = true }.buttonStyle(.link)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
            }
            if let rip = slot.rip, rip.phase != .stopped {
                // While encoding, the bar starts again and counts the encoded tracks.
                SheenProgressBar(
                    fraction: rip.phase == .finished ? 1 : rip.phase == .encoding ? rip.encodeFraction : rip.fraction,
                    verified: rip.report?.isVerified == true)
            }
            if slot.rip != nil {
                DiscGraph(tracks: graphTracks, cursor: graphCursor).padding(.top, 2)
            }
        }
    }

    private var earlierRips: [RecentRip] {
        guard let disc = slot.disc else { return [] }
        return model.earlierRips(of: disc.toc.ctdbTOCString)
    }

    /// The graph's rows: each track's state and trouble so far, with the data tracks in their places.
    private var graphTracks: [DiscGraph.Track] {
        guard let rip = slot.rip, let disc = slot.disc else { return [] }
        let data = disc.toc.tracks.filter { $0.kind == .data }.map { track in
            let saving = rip.dataTrackProgress.flatMap { $0.number == track.number ? $0.fraction : nil }
            var row = DiscGraph.dataRow(track, in: disc.toc, saved: rip.savedDataTracks[track.number], saving: saving)
            // Not saved yet: it waits, unless the rip is over or leaves it out.
            if row.dataState == "not saved", rip.isRunning, rip.savesDataTracks != false {
                row.isSkipped = false
                row.dataState = rip.savesDataTracks == true ? "to be saved after the music" : "waiting for your answer"
            }
            return row
        }
        let audio = disc.toc.audioTracks.map { track in
            var row = DiscGraph.Track(number: track.number, sectors: disc.toc.sectorRange(of: track).count)
            if let errors = rip.trackErrors[track.number] {
                row.flagged = errors.flagged
                row.unreadable = errors.unreadable
                row.suspect = errors.suspect
                row.unresolved = errors.unresolved
            }
            switch rip.trackStates[track.number] {
            case .reading(_, _, let fraction): row.readFraction = fraction
            case .rereading, .testing: row.readFraction = 1
            case .finished(let report):
                row.readFraction = 1
                let verdict = TrackVerdict(report, ctdb: rip.ctdb)
                row.isVerified = verdict == .verified || verdict == .repaired
            case .skipped: row.isSkipped = true
            case .queued, nil: break
            }
            return row
        }
        return (audio + data).sorted { $0.number < $1.number }
    }

    private var graphCursor: (track: Int, sector: Int)? {
        guard let rip = slot.rip, rip.isRunning, let track = rip.currentTrack,
            case .reading(_, _, let fraction) = rip.trackStates[track], let errors = rip.trackErrors[track]
        else { return nil }
        return (track, Int(fraction * Double(errors.sectors)))
    }

    private var isWorking: Bool {
        slot.rip?.isRunning == true || (slot.rip == nil && slot.disc?.lookup == .lookingUp)
    }

    private var statusText: String {
        if let rip = slot.rip { return rip.statusText }
        guard let disc = slot.disc else { return "" }
        if disc.lookup == .lookingUp { return "Looking up the disc in MusicBrainz…" }
        let count = slot.selectedTracks.count
        return "Ready to rip \(count) of \(disc.toc.audioTracks.count) tracks"
    }

    private var timeLabel: some View {
        Text(timeText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
    }

    private var timeText: String {
        guard let rip = slot.rip else {
            guard let disc = slot.disc else { return "" }
            let selected = disc.toc.audioTracks.filter { slot.selectedTracks.contains($0.number) }
            let sectors = selected.reduce(0) { $0 + disc.toc.sectorRange(of: $1).count }
            return Format.duration(sectors: sectors)
        }
        guard rip.isRunning else { return "took \(Format.duration(seconds: Int(rip.elapsed)))" }
        var parts = ["\(Format.duration(seconds: Int(rip.elapsed))) elapsed"]
        // The audio read so far, until the first pass is done; re-reads and CTDB come after.
        let read = rip.sectorsDone + rip.sectorsInPass
        if read < rip.sectorsTotal {
            parts.append(Format.duration(sectors: read) + " of " + Format.duration(sectors: rip.sectorsTotal))
            if let speed = rip.speed, speed > 0 { parts.append(String(format: "%.1f×", speed)) }
            if let left = rip.secondsLeft {
                parts.append(Format.timeLeft(seconds: left) + (rip.isRereading ? ", plus re-reads" : ""))
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// After a rip: the headline, the chips, and the buttons for the folder and the report.
struct ResultBanner: View {
    @Environment(AppModel.self) private var model
    var rip: RipRun
    var report: RipReport
    var folder: URL?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: report.isVerified ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(report.isVerified ? Theme.good : Theme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text(RipRun.headline(for: report)).font(.headline)
                ChipRow(chips: ResultChips.chips(for: report))
                if let advice = report.advice {
                    Text(advice).font(.callout).foregroundStyle(.secondary)
                }
                if rip.keptFiles != nil {
                    Text("Not encoded: the library keeps the files it had. The rip is in the rips folder.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if rip.notEncodedUnverified {
                    Text(
                        "Not encoded, because the rip is not verified. Listen to it first; if it sounds right, "
                            + "Encode… accepts it as it is."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
                if let music = rip.musicResult {
                    Text(music).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let folder, !report.isVerified, report.ctdb.status != .notInDatabase {
                Button("Repair…") { model.startRepair(RecentRip(folder: folder, report: report)) }
                    .help("Check the rip against CTDB again, pooled with the other rips of this disc, and repair it")
                    .disabled(model.repair?.isRunning == true)
            }
            if let folder, rip.notEncodedUnverified {
                Button("Encode…") {
                    if model.acceptAndEncode(RecentRip(folder: folder, report: report)) { rip.acceptedForEncoding() }
                }
                .help("Accept this rip as it is, and encode it into the library")
                .disabled(model.library?.isRunning == true)
            }
            if let folder {
                Button("Show in Finder") { model.revealInFinder(folder) }
            }
            Button("Show Log") { model.logShown = true }
        }
        .padding(12)
        .background(
            (report.isVerified ? Theme.good : Theme.warning).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Images dropped or chosen for the cover: a file, or image data from another app, made
/// into a cover the tags can hold by `CoverImage(converting:)`. One that cannot be read
/// gets an alert, so a drop or a choice never fails without a word.
enum CoverDrop {
    static func load(_ provider: NSItemProvider, then apply: @escaping @MainActor (Data) -> Void) {
        let done: @Sendable (Data?) -> Void = { image in
            Task { @MainActor in
                if let image { apply(image) } else { showUnreadable() }
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                done(data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }.flatMap(imageData(from:)))
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                done(data.flatMap(imageData(from:)))
            }
        } else {
            showUnreadable()
        }
    }

    /// Asks for an image file, of the types that can become a cover only.
    static func choose(message: String) -> Data? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = CoverImage.readableTypes
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let data = imageData(from: url) else {
            showUnreadable()
            return nil
        }
        return data
    }

    static func showUnreadable() {
        let alert = NSAlert()
        alert.messageText = "This file cannot be used as a cover"
        alert.informativeText = CoverArtError.notAnImage.description
        alert.runModal()
    }

    nonisolated static func imageData(from url: URL) -> Data? {
        (try? Data(contentsOf: url)).flatMap(imageData(from:))
    }

    /// The cover as a file to drag out: a copy in a temporary folder, named for the album,
    /// which the Finder copies where it is dropped.
    static func provider(for data: Data?, name: String) -> NSItemProvider? {
        file(for: data, name: name).flatMap { NSItemProvider(contentsOf: $0) }
    }

    /// The cover in a temporary folder, named for the album: to drag out, or for Quick Look.
    static func file(for data: Data?, name: String) -> URL? {
        guard let data, let fileExtension = CoverImage(data: data).fileExtension else { return nil }
        let folder = URL.temporaryDirectory.appending(path: "Silverside Covers", directoryHint: .isDirectory)
        let file = folder.appending(path: "\(name).\(fileExtension)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            return nil
        }
        return file
    }

    /// Saves the cover where the user says.
    static func export(_ data: Data?, name: String) {
        guard let data, let fileExtension = CoverImage(data: data).fileExtension else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).\(fileExtension)"
        panel.allowedContentTypes = [fileExtension == "png" ? .png : .jpeg]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The data as JPEG or PNG: as given if it already is one, else re-encoded as JPEG.
    nonisolated static func imageData(from data: Data) -> Data? {
        try? CoverImage(converting: data).data
    }
}

/// The choices for the next rip, in a popover from the toolbar.
struct RipOptionsView: View {
    @Environment(AppModel.self) private var model
    @Bindable var slot: DriveSlot

    private var earlierRips: [RecentRip] {
        guard let disc = slot.disc else { return [] }
        return model.earlierRips(of: disc.toc.ctdbTOCString)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("For the next rip").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Folder").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(slot.choices.folder?.path ?? "Named from the release, in the rips folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(slot.choices.folder == nil ? .secondary : .primary)
                    Spacer()
                    if slot.choices.folder != nil {
                        Button("Default") { slot.choices.folder = nil }
                    }
                    Button("Choose…") { chooseFolder() }
                }
            }
            Divider()
            Toggle(isOn: $slot.choices.poolsEarlierRips) {
                Text(
                    earlierRips.isEmpty
                        ? "Pool earlier rips of this disc (none yet)"
                        : "Pool \(Format.count(earlierRips.count, "earlier rip")) of this disc")
            }
            .disabled(earlierRips.isEmpty)
            Text(
                "Sectors that an earlier rip read right are kept, and where the rips disagree, the re-reads and the CTDB repair have more to work with."
            )
            .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("Read every track again", isOn: $slot.choices.readsEveryTrack)
            Text(
                "Without it, a track that an earlier rip has a copy of that AccurateRip says is accurate is kept, not read again: a stopped rip's tracks, or another drive's."
            )
            .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("Offline: look nothing up", isOn: $slot.choices.offline)
            Text(
                "No AccurateRip, CTDB, or drive offset list. The names come from the lookup already made. Repair can check the rip later."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 400)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Rip Here"
        panel.message = "The rip's WAV files, report, and cover go in this folder."
        panel.directoryURL = model.settings.ripsURL
        if panel.runModal() == .OK, let url = panel.url { slot.choices.folder = url }
    }
}

/// A row of chips that wraps onto more rows when there are many, so it never widens the window.
struct ChipRow: View {
    var chips: [Chip]

    var body: some View {
        FlowLayout {
            ForEach(chips, id: \.text) { $0 }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The chips that sum up a report: AccurateRip, CTDB, re-reads, repairs, HDCD.
enum ResultChips {
    /// The HDCD logo, and what the codes of these tracks ask for. Nil if none has codes.
    static func hdcd(_ tracks: [RipReport.Track]) -> Chip? {
        let codes = tracks.compactMap(\.hdcd)
        guard !codes.isEmpty else { return nil }
        var features = [String]()
        if codes.contains(where: { $0.peakExtend != .never }) { features.append("peak extend") }
        if codes.contains(where: { $0.maxGainAdjustment < 0 }) { features.append("gain") }
        return Chip(
            text: features.isEmpty ? "codes only" : features.joined(separator: ", "), logo: "HDCD",
            help: HDCDStatus.text(for: tracks))
    }

    /// For a disc that MusicBrainz does not know: a click opens MusicBrainz's release editor with
    /// the disc's names, track lengths, and TOC filled in, for the user to check and submit.
    static func addToMusicBrainz(_ release: MusicBrainzRelease, toc: TOC) -> Chip {
        Chip(
            text: "Add to MusicBrainz…", systemImage: "plus",
            help: "Opens MusicBrainz's release editor in your browser with a new release: this disc's names, "
                + "track lengths, and disc ID. Use it only when MusicBrainz has no release of this disc; search "
                + "there first. If it has the release, use Add Disc ID… instead. Check and complete the new "
                + "release, and submit it (you need an account). Then use Look Up Metadata.",
            action: {
                if let page = try? MusicBrainzSeed.writePage(for: release, toc: toc) { NSWorkspace.shared.open(page) }
            })
    }

    /// For a disc that MusicBrainz does not know: a click opens the page that finds a release
    /// in MusicBrainz and adds the disc ID to it.
    static func addDiscID(toc: TOC) -> Chip {
        let count = toc.audioTracks.count
        return Chip(
            text: "Add Disc ID…", systemImage: "link",
            help: "When MusicBrainz has the release of this disc, but not its disc ID: opens MusicBrainz in your "
                + "browser, where you find the release and add the disc ID to it (you need an account). MusicBrainz "
                + "offers only releases with \(count) \(count == 1 ? "track" : "tracks"), as on this disc; if the "
                + "release's track list differs, such as one copied from a cover that counts takes the disc does "
                + "not, correct it there first. Then use Look Up Metadata.",
            link: MusicBrainzRelease.submissionURL(for: toc))
    }

    /// Opens MusicBrainz's release editor with a new release of this disc alone, copied from
    /// `release`, which has the disc as one of its discs: for an edition that MusicBrainz lacks.
    static func openNewRelease(copying release: MusicBrainzRelease, toc: TOC) {
        if let page = try? MusicBrainzSeed.writePage(for: release, toc: toc, newRelease: true) {
            NSWorkspace.shared.open(page)
        }
    }

    /// The help for the commands that open it.
    static let newReleaseHelp =
        "For an edition of this disc that MusicBrainz does not have, such as the single-disc edition of a set's "
        + "first disc: opens MusicBrainz's release editor in your browser with a new release copied from this one, "
        + "with this disc's tracks, lengths, and disc ID. Add your edition's barcode, catalog number, and format "
        + "there, and submit it (you need an account). Then use Look Up Metadata."

    /// The tooltip of a release that MusicBrainz found by the disc ID: enough to tell it from
    /// the other releases of the album, such as a set with a Blu-ray.
    static func discIDMatchHelp(_ release: MusicBrainzRelease) -> String {
        let labels = release.labels.compactMap { label in
            [label.name, label.catalogNumber].compactMap { $0 }.joined(separator: " ")
        }.filter { !$0.isEmpty }
        let details = [release.formats] + labels + [release.country, release.date].compactMap { $0 }
        return "MusicBrainz knows this exact disc, on \(release.title) (\(details.joined(separator: ", "))). "
            + "Click to open the release in MusicBrainz."
    }

    /// For a release that MusicBrainz matched by its track lengths: a click opens the page
    /// that adds the disc ID to it.
    static func lengthsMatch(toc: TOC) -> Chip {
        Chip(
            text: "MusicBrainz · nearly the same TOC", tone: .warning, systemImage: "approximatelyequal",
            help: "MusicBrainz does not know this disc ID, so the release was matched by its track lengths. "
                + "Click to add the disc ID to the right release in MusicBrainz (you need an account); "
                + "after that, every ripper finds the disc by its ID.",
            link: MusicBrainzRelease.submissionURL(for: toc))
    }

    /// For a disc whose ID MusicBrainz has on other releases only, when a release of earlier
    /// rips has a disc with its track lengths: a click opens the page that adds the disc ID to it.
    static func earlierRelease(
        _ release: MusicBrainzRelease, medium: MusicBrainzRelease.Medium, found: MusicBrainzRelease, toc: TOC
    ) -> Chip {
        let count = release.media.count
        // The catalog number (else the country) tells two editions with one title apart.
        func name(_ release: MusicBrainzRelease) -> String {
            let edition = release.labels.compactMap(\.catalogNumber).first ?? release.country
            return release.title + (edition.map { " (\($0))" } ?? "")
        }
        let disc = count > 1 ? "its disc \(medium.position)" : "it"
        return Chip(
            text: count > 1
                ? "Disc \(medium.position) of your \(count)-disc \(release.title)?" : "Your \(release.title)?",
            tone: .warning, systemImage: "questionmark",
            help: "Your earlier rips of \(name(release)) have a disc with this disc's track lengths, but MusicBrainz "
                + "has this disc ID only on \(name(found)), so the lookup cannot find \(name(release)). Editions "
                + "often have the same disc, so a disc ID can be on both. If this disc is from \(name(release)), "
                + "click to add the disc ID to \(disc) in MusicBrainz (you need an account), then use Look Up "
                + "Metadata. Remove the disc ID from the other release only if that release is wrong.",
            link: MusicBrainzRelease.submissionURL(for: toc))
    }

    static func chips(for report: RipReport) -> [Chip] {
        var chips = [Chip]()
        let accurate = report.tracks.filter { $0.accurateRip == .accurate }.count
        let others = report.tracks.filter { $0.accurateRip == .otherPressings }.count
        // AccurateRip cannot check a track it has no checksum for (a silent one), so it is not counted.
        let noChecksumTracks = report.tracks.filter { $0.accurateRip == .noChecksum }
        let noChecksum = noChecksumTracks.count
        let total = report.tracks.count - noChecksum
        if report.tracks.allSatisfy({ $0.accurateRip == .notInDatabase }) {
            chips.append(Chip(text: "Not in AccurateRip"))
        } else {
            let matched = accurate + others
            let tone: Chip.Tone = matched == total ? .good : .warning
            // One count for both, so "0 / 13" does not read as a failure; the tooltip tells them apart.
            chips.append(
                Chip(
                    text: "AccurateRip \(matched) / \(total)", tone: tone,
                    help: others == 0
                        ? nil
                        : (others == 1 ? "1 track matches" : "\(others) tracks match")
                            + " AccurateRip at another pressing's offset. The audio is the same, but it sits some"
                            + " samples earlier or later on this disc than on the discs in the database. The drive's"
                            + " own offset is already corrected, so the difference is in the disc: pressings from"
                            + " other plants or years often differ this way. Burned CD-R copies are sometimes offset"
                            + " by a few samples."))
            if noChecksum > 0 {
                // AccurateRip keeps no checksum for silence: say so when that is why.
                let allSilent = noChecksumTracks.allSatisfy(\.isSilent)
                chips.append(
                    Chip(
                        text: allSilent
                            ? Format.count(noChecksum, "silent track") + " (no AccurateRip checksum)"
                            : Format.count(noChecksum, "track") + " with no checksum",
                        help: "AccurateRip has this disc, but no checksum for "
                            + (noChecksum == 1
                                ? "this track, so it cannot check it" : "these tracks, so it cannot check them")
                            + ". It keeps none for a track that is all silence."))
            }
        }
        if let accepted = report.accepted, !report.isVerified {
            let unverified = report.unverifiedTracks
            chips.append(
                Chip(
                    text: "Accepted as-is", tone: .warning, systemImage: "hand.thumbsup",
                    help: "You accepted this rip on \(accepted.formatted(date: .abbreviated, time: .shortened)), with "
                        + "\(unverified.count == 1 ? "track" : "tracks") \(RipSet.list(unverified)) not verified, "
                        + "and it was encoded as a verified rip is. Check Again can still verify it later."))
        }
        switch report.ctdb.status {
        case .verified: chips.append(Chip(text: "CTDB verified", tone: .good))
        case .repaired: chips.append(Chip(text: "CTDB repaired", tone: .good))
        case .partlyRepaired: chips.append(Chip(text: "CTDB partly repaired", tone: .warning))
        case .notVerified: chips.append(Chip(text: "CTDB not verified", tone: .bad))
        case .notInDatabase: chips.append(Chip(text: "Not in CTDB"))
        case .notChecked: break
        }
        let suspects = report.tracks.reduce(0) { $0 + $1.suspectSectors.count }
        let unresolved = report.tracks.reduce(0) { $0 + $1.unresolvedSectors.count }
        let repaired = report.tracks.reduce(0) { $0 + $1.repairedSamples }
        if suspects > 0 {
            var text = Format.count(suspects, "sector") + " re-read"
            if unresolved > 0 {
                // Verified as it is, the values that the re-reads settled on were right; repaired, CTDB fixed them.
                text +=
                    !report.isVerified
                    ? ", \(unresolved) never agreed"
                    : report.ctdb.status == .verified
                        ? ", \(unresolved) confirmed by CTDB" : ", \(unresolved) fixed by CTDB"
            }
            chips.append(Chip(text: text, tone: unresolved > 0 && !report.isVerified ? .bad : .warning))
        } else if unresolved > 0 {
            chips.append(Chip(text: "\(unresolved) sectors unresolved", tone: report.isVerified ? .warning : .bad))
        }
        if repaired > 0 { chips.append(Chip(text: "\(repaired.formatted()) samples repaired", tone: .warning)) }
        if report.hdcd != nil, let chip = hdcd(report.tracks) { chips.append(chip) }
        if let text = report.dtsText {
            chips.append(
                Chip(
                    text: report.encoding?.dtsDecoded.map { "DTS · decoded to \($0)" } ?? "DTS stream",
                    systemImage: "hifispeaker.2",
                    help: text
                        + (report.encoding?.dtsDecoded == nil
                            ? " Decode DTS… in the toolbar makes a decoded copy, with ffmpeg." : "")))
        }
        let emphasized = report.tracks.filter(\.preEmphasis)
        if !emphasized.isEmpty {
            let qOnly = emphasized.allSatisfy { $0.tocFlags?.preEmphasis == false }
            chips.append(
                Chip(
                    text: emphasized.count == report.tracks.count
                        ? "Pre-emphasis" : "Pre-emphasis · " + Format.count(emphasized.count, "track"),
                    help: "The disc marks these tracks as mastered with pre-emphasis, a treble boost that a CD player"
                        + " takes out again. "
                        + (report.encoding?.deEmphasizedTracks?.isEmpty == false
                            ? "The files hold them de-emphasized, as a CD player plays them, tagged DE_EMPHASIZED=yes."
                            : "The files keep the audio as on the disc, tagged PRE_EMPHASIS=yes, so a player that"
                                + " ignores the flag plays them too bright. The CUE sheet marks them (FLAGS PRE).")
                        + (qOnly ? " The flag is in the Q subchannel only, not in the TOC." : "")))
        }
        let fourChannel = report.tracks.filter(\.isFourChannel)
        if !fourChannel.isEmpty {
            chips.append(
                Chip(
                    text: "Four-channel audio · " + Format.count(fourChannel.count, "track"), tone: .warning,
                    help: "The disc's control bits say four-channel audio: a mode in early versions of the CD"
                        + " standard that no player supports and no released disc is known to use (the 1999 edition"
                        + " gives the bit to broadcasting). Silverside ripped the"
                        + " audio as two channels, as on any CD. The report has the details."))
        }
        if let saved = report.dataTracks {
            chips.append(
                Chip(
                    text: "Data track saved", systemImage: "externaldrive",
                    help: "The disc's data track, with extras for a computer: "
                        + saved.map { "\($0.file), \($0.sectors.formatted()) sectors" }.joined(separator: "; ")
                        + ". The encoding copies it into the album folder as Data track.iso, with its files"
                        + " beside it in the Data track folder."))
        }
        if let failures = report.dataTrackFailures, !failures.isEmpty {
            chips.append(
                Chip(
                    text: "Data track not saved", tone: .warning, systemImage: "externaldrive.badge.xmark",
                    help: failures.map { "Data track \($0.number): \($0.reason)" }.joined(separator: " ")
                        + " The audio's rip is whole. To save the data track, put the disc in a drive and use"
                        + " Save Data Track… in the toolbar; another drive may read it."))
        }
        if let encoding = report.encoding {
            let leftOut = encoding.silentTracksLeftOut ?? []
            let all = encoding.files.count + leftOut.count >= report.tracks.count
            chips.append(
                Chip(
                    text: "Encoded · \(encoding.format.rawValue.uppercased())"
                        + (encoding.hdcdDecoded == true ? " · HDCD decoded" : "")
                        + (encoding.dtsDecoded.map { " · DTS \($0)" } ?? "")
                        + (encoding.deEmphasizedTracks?.isEmpty == false ? " · de-emphasized" : "")
                        + (all ? "" : " · \(encoding.files.count) tracks"),
                    tone: all ? .good : .warning, systemImage: "music.note",
                    help: Self.encodedHelp(encoding)))
        }
        return chips
    }

    /// The Encoded chip's tooltip: what a DTS decode is, and the silent tracks left out. Nil if neither.
    private static func encodedHelp(_ encoding: RipReport.Encoding) -> String? {
        var parts = [String]()
        // "FLAC · DTS 5.1" is not a DTS stream in FLAC: say so.
        if let layout = encoding.dtsDecoded {
            parts.append(
                "\(encoding.format.name) files of \(layout) audio, decoded from the disc's DTS stream: each "
                    + "channel is plain audio, which any player plays with no DTS decoder.")
        }
        if let leftOut = encoding.silentTracksLeftOut, !leftOut.isEmpty {
            parts.append(
                (leftOut.count == 1 ? "Track " : "Tracks ") + RipReport.list(leftOut)
                    + ": digital silence, left out of the album.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
