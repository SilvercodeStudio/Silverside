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
                NoDiscView(driveName: slot.name)
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
                if slot.disc != nil { DiscView(slot: slot, releasePickerShown: $releasePickerShown) }
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
            .disabled(slot.device.discBSDName == nil || isRipping)

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
                    RipButton(slot: slot)
                        .padding([.top, .bottom, .leading], RipButton.inset)
                        .padding(.trailing, RipButton.trailingInset)
                        .frame(maxWidth: .infinity, alignment: .trailing)
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
                    CoverDrop.load(provider) { data in
                        if let data { slot.disc?.userCover = CoverImage(data: data) }
                    }
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
                        shown: disc.title(from: source), editable: editable)
                    EditableField(
                        label: disc.yearIsFirstRelease ? "First Release" : "Date",
                        text: field(\.date, original: disc.baseRelease?.date),
                        shown: disc.shownRelease?.date ?? disc.release?.releaseGroup?.firstReleaseDate ?? "—",
                        prompt: disc.yearIsFirstRelease ? disc.release?.releaseGroup?.firstReleaseDate : nil,
                        editable: editable
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
                        shown: disc.artist(from: source).isEmpty ? "—" : disc.artist(from: source), editable: editable)
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
                        hdcdChip
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
                        if let discLabel = disc.discLabel { Chip(text: discLabel) }
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
                        InfoButton(help: "Disc info: the release as MusicBrainz has it, and the disc's own codes") {
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
            }
        }
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
        if let release = disc.release { try? ReleaseCoverStore().forget(releaseID: release.id) }
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an image for the cover. JPEG and PNG are kept as they are; other formats become JPEG."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = CoverDrop.imageData(from: url) { slot.disc?.userCover = CoverImage(data: data) }
    }

    /// A binding to one album-level edit: the original value clears the edit.
    private func field(_ key: WritableKeyPath<MetadataEdits, String?>, original: String?) -> Binding<String> {
        Binding(
            get: { slot.disc?.edits[keyPath: key] ?? original ?? "" },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                slot.disc?.edits[keyPath: key] = trimmed.isEmpty || trimmed == original ? nil : trimmed
            })
    }

    /// HDCD, from the codes in the tracks ripped so far; before that, from MusicBrainz's format for the disc.
    @ViewBuilder private var hdcdChip: some View {
        let ripped = (slot.rip?.trackStates.values ?? [:].values).compactMap { state -> RipReport.Track? in
            if case .finished(let track) = state { track } else { nil }
        }
        if let chip = ResultChips.hdcd(ripped.sorted { $0.number < $1.number }) {
            chip
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
            Chip(text: "MusicBrainz · several releases match", tone: .warning, systemImage: "questionmark")
        case .found where disc.isFuzzy:
            ResultChips.lengthsMatch(toc: disc.toc)
        case .found:
            Chip(text: "MusicBrainz · Disc ID match", tone: .good, systemImage: "checkmark")
        case .notFound:
            Chip(
                text: disc.hasCDText
                    ? "Not in MusicBrainz · names from CD-Text" : "Not in MusicBrainz · type the names",
                tone: .warning, systemImage: "xmark"
            )
            .help("The files get no MusicBrainz IDs. Edit the names here; they are kept with the rip.")
            if let release = disc.shownRelease { ResultChips.addToMusicBrainz(release, toc: disc.toc) }
        case .failed:
            Chip(text: "MusicBrainz · lookup failed", tone: .bad, systemImage: "wifi.slash")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Group {
                if editable {
                    TextField("", text: $text, prompt: prompt.map { Text($0) }).textFieldStyle(.plain)
                } else {
                    Text(shown).lineLimit(1)
                }
            }
            .font(.title3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(editable ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: 6))
        }
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
                Text(timeText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
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

    /// The graph's rows: each track's state and trouble so far.
    private var graphTracks: [DiscGraph.Track] {
        guard let rip = slot.rip, let disc = slot.disc else { return [] }
        return disc.toc.audioTracks.map { track in
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

    private var timeText: String {
        guard let rip = slot.rip else {
            guard let disc = slot.disc else { return "" }
            let selected = disc.toc.audioTracks.filter { slot.selectedTracks.contains($0.number) }
            let sectors = selected.reduce(0) { $0 + disc.toc.sectorRange(of: $1).count }
            return Format.duration(sectors: sectors)
        }
        guard rip.isRunning else { return "took \(Format.duration(seconds: Int(rip.elapsed)))" }
        var text =
            Format.duration(sectors: rip.sectorsDone + rip.sectorsInPass) + " of "
            + Format.duration(sectors: rip.sectorsTotal)
        if let speed = rip.speed, speed > 0 { text += String(format: " · %.1f×", speed) }
        if let left = rip.secondsLeft {
            text += " · " + Format.timeLeft(seconds: left) + (rip.isRereading ? ", plus re-reads" : "")
        }
        return text
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

/// Images dropped or chosen for the cover: a file, or image data from another app. JPEG
/// and PNG are kept byte for byte; anything else becomes a JPEG, because that is what the
/// tags can hold.
enum CoverDrop {
    static func load(_ provider: NSItemProvider, then apply: @escaping @MainActor (Data?) -> Void) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                let image = url.flatMap(imageData(from:))
                Task { @MainActor in apply(image) }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                let image = data.flatMap(imageData(from:))
                Task { @MainActor in apply(image) }
            }
        } else {
            apply(nil)
        }
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
        if CoverImage(data: data).fileExtension != nil { return data }
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
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
            help: "Opens MusicBrainz's release editor in your browser with this disc's names, track lengths, and "
                + "disc ID filled in. Check and complete it there, and submit it (you need an account, and to be "
                + "signed in). Then every ripper finds the disc by its ID.",
            action: {
                if let page = try? MusicBrainzSeed.writePage(for: release, toc: toc) { NSWorkspace.shared.open(page) }
            })
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

    static func chips(for report: RipReport) -> [Chip] {
        var chips = [Chip]()
        let accurate = report.tracks.filter { $0.accurateRip == .accurate }.count
        let others = report.tracks.filter { $0.accurateRip == .otherPressings }.count
        // AccurateRip cannot check a track it has no checksum for (a silent one), so it is not counted.
        let noChecksum = report.tracks.filter { $0.accurateRip == .noChecksum }.count
        let total = report.tracks.count - noChecksum
        if report.tracks.allSatisfy({ $0.accurateRip == .notInDatabase }) {
            chips.append(Chip(text: "Not in AccurateRip"))
        } else {
            chips.append(Chip(text: "AccurateRip \(accurate) / \(total)", tone: accurate == total ? .good : .warning))
            if others > 0 { chips.append(Chip(text: "\(others) match other pressings", tone: .good)) }
            if noChecksum > 0 {
                chips.append(
                    Chip(
                        text: Format.count(noChecksum, "track") + " with no checksum",
                        help: "AccurateRip has this disc, but no checksum for "
                            + (noChecksum == 1
                                ? "this track, so it cannot check it" : "these tracks, so it cannot check them")
                            + ". It keeps none for a track that is all silence."))
            }
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
                text += report.isVerified ? ", \(unresolved) fixed by CTDB" : ", \(unresolved) never agreed"
            }
            chips.append(Chip(text: text, tone: unresolved > 0 && !report.isVerified ? .bad : .warning))
        } else if unresolved > 0 {
            chips.append(Chip(text: "\(unresolved) sectors unresolved", tone: report.isVerified ? .warning : .bad))
        }
        if repaired > 0 { chips.append(Chip(text: "\(repaired.formatted()) samples repaired", tone: .warning)) }
        if report.hdcd != nil, let chip = hdcd(report.tracks) { chips.append(chip) }
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
                                + " ignores the flag plays them too bright.")
                        + " The CUE sheet marks them (FLAGS PRE)."
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
        if let encoding = report.encoding {
            let all = encoding.files.count >= report.tracks.count
            chips.append(
                Chip(
                    text: "Encoded · \(encoding.format.rawValue.uppercased())"
                        + (encoding.hdcdDecoded == true ? " · HDCD decoded" : "")
                        + (encoding.deEmphasizedTracks?.isEmpty == false ? " · de-emphasized" : "")
                        + (all ? "" : " · \(encoding.files.count) tracks"),
                    tone: all ? .good : .warning, systemImage: "music.note"))
        }
        return chips
    }
}
