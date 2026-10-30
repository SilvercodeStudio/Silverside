import AppKit
import SilversideDarwin
import SilversideKit
import SwiftUI

/// The settings window. Every setting is in the file that `silverside config` shares.
struct SettingsView: View {
    enum Tab: String { case general, drives, ripping, encoding, naming }
    /// Debug builds can start on a tab with `-settingsTab drives`.
    @State private var tab = Tab(rawValue: UserDefaults.standard.string(forKey: "settingsTab") ?? "") ?? .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "slider.horizontal.3") }.tag(Tab.general)
            DriveSettings().tabItem { Label("Drives", systemImage: "opticaldiscdrive") }.tag(Tab.drives)
            RippingSettings().tabItem { Label("Ripping", systemImage: "arrow.down.circle") }.tag(Tab.ripping)
            EncodingSettings().tabItem { Label("Encoding", systemImage: "waveform") }.tag(Tab.encoding)
            NamingSettings().tabItem { Label("Naming", systemImage: "textformat") }.tag(Tab.naming)
        }
        .frame(width: 640, height: 520)
        // No field takes focus by itself: a blinking cursor in the library path invites a slip.
        .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var lame = MP3Encoder.lame()

    /// MP3 only with lame, unless the settings already chose it: the menu still shows that choice.
    private var formats: [AudioFormat] {
        AudioFormat.allCases.filter { $0 != .mp3 || lame != nil || model.settings.format == .mp3 }
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Folders") {
                FolderField(label: "Music library", path: $model.settings.library)
                Text("Encoded albums go here, in folders named by the Naming settings.")
                    .font(.caption).foregroundStyle(.secondary)
                FolderField(label: "Rips", path: $model.settings.rips)
                Text(
                    "Each rip's WAV files, report, and cover, until the rip is encoded. Keep rips out of the library: music apps would import the WAV files."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("After a rip") {
                Toggle("Encode the disc into the library", isOn: $model.settings.encodeAfterRip)
                Picker("Format", selection: $model.settings.format) {
                    ForEach(formats, id: \.self) { Text(formatName($0)).tag($0) }
                }
                .disabled(!model.settings.encodeAfterRip)
                if lame == nil {
                    Text(
                        model.settings.format == .mp3
                            ? "MP3 needs the LAME encoder, which is not installed, so rips are not encoded. Install it with brew install lame, or choose another format."
                            : "MP3 is a choice once the LAME encoder is installed: brew install lame."
                    )
                    .font(.caption).foregroundStyle(Theme.warning)
                }
                Toggle("Keep the rip's WAV files after encoding", isOn: $model.settings.keepRipAfterEncoding)
                    .disabled(!model.settings.encodeAfterRip)
                Text(
                    "Otherwise a rip whose tracks are all verified and encoded is deleted, and its report goes in the album folder."
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle("Add the files to Apple's Music app", isOn: $model.settings.addToMusic)
                    .disabled(!model.settings.encodeAfterRip || !MusicApp.reads(model.settings.format))
                Text(
                    MusicApp.reads(model.settings.format)
                        ? "Music adds them where they are, or copies them if its own settings say so. macOS asks once whether Silverside may control Music."
                        : "Music cannot read FLAC files. Choose Apple Lossless to add rips to Music."
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle("Eject the disc if every track is verified", isOn: $model.settings.ejectAfterRip)
            }
            Section("When a disc goes in") {
                Toggle("Rip it at once", isOn: $model.settings.ripOnInsert)
                Text(
                    "Only when MusicBrainz names the disc's release for certain, and the disc is not ripped yet. The rip starts after a few seconds, so you can cancel it; otherwise the disc waits for you."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Artwork") {
                Picker("Save from the Cover Art Archive", selection: $model.settings.artwork) {
                    Text("Front cover").tag(ArtworkChoice.front)
                    Text("All images").tag(ArtworkChoice.all)
                    Text("None").tag(ArtworkChoice.none)
                }
            }
        }
        .formStyle(.grouped)
        .watchingForLAME($lame)
    }

    private func formatName(_ format: AudioFormat) -> String {
        switch format {
        case .flac: "FLAC"
        case .alac: "Apple Lossless (ALAC)"
        case .aac: "AAC"
        case .aiff: "AIFF"
        case .wav: "WAV"
        case .mp3: "MP3 (external encoder)"
        }
    }
}

/// A path with a Choose button.
struct FolderField: View {
    var label: String
    @Binding var path: String

    var body: some View {
        LabeledContent(label) {
            HStack {
                TextField("", text: $path).labelsHidden().textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = Settings.expand(path)
                    if panel.runModal() == .OK, let url = panel.url {
                        let home = URL.homeDirectory.path
                        path = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
                    }
                }
            }
        }
    }
}

struct DriveSettings: View {
    @Environment(AppModel.self) private var model
    @State private var store = try? DriveProfileStore()
    @State private var selectedKey: String?
    @State private var manualOffset = ""
    @State private var message: String?
    @State private var testRun: DriveTestRun?

    private var profiles: [DriveProfile] {
        var all = store?.profiles ?? [:]
        // The demo's simulated drive is listed too, so the checks can be tried without hardware.
        for slot in model.drives {
            let identity = slot.identity
            if all[DriveProfile(vendor: identity.vendor, product: identity.product, revision: identity.revision).key]
                == nil
            {
                let profile = DriveProfile(
                    vendor: identity.vendor, product: identity.product, revision: identity.revision)
                all[profile.key] = profile
            }
        }
        return all.values.sorted { $0.key < $1.key }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(profiles, id: \.key, selection: $selectedKey) { profile in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(profile.vendor) \(profile.product)").lineLimit(1)
                    Text(offsetSummary(profile)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .tag(profile.key)
            }
            .frame(width: 230)
            Divider().padding(.vertical, 12)
            Group {
                if let profile = profiles.first(where: { $0.key == selectedKey }) {
                    details(profile)
                } else {
                    Text("Select a drive").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            if selectedKey == nil { selectedKey = profiles.first?.key }
            #if DEBUG
                // `-driveTest test` or `-driveTest cache` runs a check of the demo drive at once, for screenshots.
                if let kind = UserDefaults.standard.string(forKey: "driveTest"),
                    let slot = model.drives.first(where: \.isDemo),
                    let profile = profiles.first(where: { matches(slot, $0) })
                {
                    selectedKey = profile.key
                    DispatchQueue.main.async { start(kind == "cache" ? .cache : .test, profile) }
                }
            #endif
        }
        .onChange(of: selectedKey) { _, key in
            manualOffset = profiles.first { $0.key == key }?.manualOffset.map(String.init) ?? ""
        }
        .sheet(item: $testRun, onDismiss: { store = try? DriveProfileStore() }, content: { DriveTestSheet(run: $0) })
    }

    private func matches(_ slot: DriveSlot, _ profile: DriveProfile) -> Bool {
        slot.identity == DriveIdentity(vendor: profile.vendor, product: profile.product, revision: profile.revision)
    }

    /// The drive of a profile, when it holds a disc and nothing else uses it.
    private func slot(for profile: DriveProfile) -> DriveSlot? {
        model.drives.first { matches($0, profile) && $0.disc != nil && $0.rip?.isRunning != true && !$0.isBusy }
    }

    private func checksHint(for profile: DriveProfile) -> String {
        guard let slot = slot(for: profile) else {
            return "Put a clean audio CD in the drive first. The checks read near its start and end."
        }
        return
            "With the disc in \(slot.name). The checks take about 20 seconds, the measurement up to a minute; use a clean disc, because they read near its start and end."
    }

    private func start(_ kind: DriveTestRun.Kind, _ profile: DriveProfile) {
        guard let slot = slot(for: profile) else { return }
        let run = DriveTestRun(kind: kind, slot: slot)
        testRun = run
        run.start(profile: profile) { store = try? DriveProfileStore() }
    }

    private func offsetSummary(_ profile: DriveProfile) -> String {
        guard let (value, source) = profile.offset else { return "No read offset yet" }
        return "Offset \(value.signedDescription) · \(source.description)"
    }

    private func details(_ profile: DriveProfile) -> some View {
        Form {
            Section {
                LabeledContent("Drive", value: "\(profile.vendor) \(profile.product)")
                LabeledContent("Firmware", value: profile.revision)
            }
            Section("Read offset") {
                LabeledContent("In use") {
                    Text(
                        profile.offset.map { "\($0.value.signedDescription) samples, \($0.source.description)" }
                            ?? "Not known: the first online rip looks it up")
                }
                if let listed = profile.listedOffset {
                    LabeledContent("AccurateRip's drive list", value: listed.signedDescription)
                }
                if let confirmed = profile.confirmedOffset {
                    LabeledContent("Confirmed by rips", value: confirmed.signedDescription)
                }
                LabeledContent("Set by hand") {
                    HStack {
                        TextField("samples", text: $manualOffset)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                        Button("Set") { save(profile) { $0.manualOffset = Int(manualOffset) } }
                            .disabled(Int(manualOffset) == nil)
                        Button("Clear") {
                            manualOffset = ""
                            save(profile) { $0.manualOffset = nil }
                        }
                        .disabled(profile.manualOffset == nil)
                    }
                }
                Text(
                    "An offset set by hand overrides the others. Find a drive's offset from the offsets that several discs share, or from AccurateRip's list."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Rips") {
                if profile.observations.isEmpty {
                    Text("No rip has checked this drive against AccurateRip yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(profile.observations.suffix(8).enumerated()), id: \.offset) { _, observation in
                    LabeledContent {
                        offsetsText(observation.offsets, winner: profile.offset?.value)
                    } label: {
                        Text(title(of: observation)).lineLimit(1).truncationMode(.middle)
                            .help(
                                observation.disc + " · "
                                    + observation.date.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                Text(
                    "Each disc that AccurateRip knows matches at the drive's offset, and often at other pressings' offsets too. The offset that every disc shares is the drive's."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cache") {
                LabeledContent("Measured cache") {
                    Text(profile.cacheSectors.map { "\($0) sectors" } ?? "Not measured: a large, safe flush is used")
                }
                LabeledContent("Flush before a re-read", value: "\(profile.cacheFlushSectors) sectors")
            }
            Section("Checks") {
                HStack {
                    Button("Test Drive…") { start(.test, profile) }
                        .help("Read the TOC, audio, C2 flags, and the Q subchannel, and time the reads")
                    Button("Measure Cache") { start(.cache, profile) }
                        .help("Time re-reads to find how many sectors the drive keeps in memory")
                }
                .disabled(slot(for: profile) == nil)
                Text(checksHint(for: profile)).font(.caption).foregroundStyle(.secondary)
            }
            if let message { Text(message).foregroundStyle(Theme.bad) }
        }
        .formStyle(.grouped)
    }

    /// The disc's name: from the observation, else from a rip of the disc in the rips folder, else its ID.
    private func title(of observation: DriveProfile.Observation) -> String {
        if let title = observation.title { return title }
        if let rip = model.recentRips.first(where: { $0.report.accurateRipDiscID == observation.disc }) {
            return rip.artist.isEmpty ? rip.title : "\(rip.artist) - \(rip.title)"
        }
        return observation.disc
    }

    /// The offsets a disc matched, with the drive's own in bold.
    private func offsetsText(_ offsets: [Int], winner: Int?) -> Text {
        offsets.enumerated().reduce(Text("")) { text, item in
            let value = Text(item.element.signedDescription)
            let shown = item.element == winner ? value.bold().foregroundColor(Theme.good) : value
            return text + (item.offset == 0 ? shown : Text(", ") + shown)
        }
    }

    private func save(_ profile: DriveProfile, change: (inout DriveProfile) -> Void) {
        var changed = profile
        change(&changed)
        // The demo drive's profile stays out of the real profiles.
        guard !model.drives.contains(where: { $0.isDemo && matches($0, profile) }) else { return }
        do {
            try store?.save(changed)
            message = nil
        } catch {
            message = "The profile could not be saved: \(error)"
        }
    }
}

struct RippingSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Reading") {
                Toggle("Ask the drive for C2 error flags", isOn: $model.settings.readC2)
                Text(
                    "C2 flags mark sectors the drive had trouble with, so they are re-read first. They are a hint only: results on damaged areas can change between reads."
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle("Test and copy: read each track once more after its rip", isOn: $model.settings.testAndCopy)
                Text(
                    "The report keeps the CRC-32 of both reads, as Exact Audio Copy does. The rip already compares reads of every doubtful sector, so this is a check for the record, and it takes as long as another read of the disc."
                )
                .font(.caption).foregroundStyle(.secondary)
                Picker("Data tracks (Enhanced CDs)", selection: $model.settings.dataTracks) {
                    Text("Ask each time").tag(DataTrackChoice.ask)
                    Text("Save").tag(DataTrackChoice.save)
                    Text("Audio only").tag(DataTrackChoice.skip)
                }
                Text(
                    "Some CDs have a data track with extras for a computer, such as videos. Save puts a disc image of it (Data track.iso) in the album's folder, and a Data track folder with the files on it, ready to open."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("How a rip works") {
                Text(
                    "Each track is read once with the drive's offset corrected, and checked against AccurateRip. A track that does not match is read again, and the sectors that differ are re-read until they agree. Then the whole disc is checked against CUETools DB and, if it has errors, repaired with CTDB's data. Fast mode in the toolbar reads each track once, with no re-reads."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Looks for `lame` every 2 seconds while a view shows, so that an install in Terminal
/// turns MP3 on in the welcome and in Settings without reopening either.
extension View {
    func watchingForLAME(_ lame: Binding<URL?>) -> some View {
        task {
            while !Task.isCancelled {
                let found = MP3Encoder.lame()
                if found != lame.wrappedValue { lame.wrappedValue = found }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

struct EncodingSettings: View {
    @Environment(AppModel.self) private var model
    @State private var lame = MP3Encoder.lame()
    @State private var ffmpeg = FFmpeg.program()

    var body: some View {
        @Bindable var model = model
        Form {
            // The chosen format and its own options, first; the other formats' options do not apply.
            Section {
                LabeledContent {
                    Text(model.settings.format.name)
                } label: {
                    Text("Format")
                    Text("Chosen in General")
                }
                switch model.settings.format {
                case .aac: aacOptions
                case .mp3: mp3Options
                case .flac, .alac, .aiff, .wav:
                    Text(
                        "\(model.settings.format.name) has no options. Each file is decoded again after encoding and compared with the audio it was made from: the rip, or the rip after HDCD decoding, de-emphasis, or DTS decoding."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Tags") {
                Toggle("ReplayGain: volume normalization tags", isOn: $model.settings.replayGain)
                Text(
                    "Adds tags that compatible players use to play entire albums at a consistent volume level. The audio samples themselves are not changed. Ignored by Apple's Music app, which uses its own Sound Check instead."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("HDCD") {
                Picker("Discs whose HDCD codes change the audio", selection: $model.settings.hdcd) {
                    Text("Ask each time").tag(HDCDChoice.ask)
                    Text("Decode").tag(HDCDChoice.decode)
                    Text("Keep as pressed").tag(HDCDChoice.keep)
                }
                Text(
                    "A few HDCD discs have codes that ask a player to expand the loudest peaks or lower the level. Decode gives the adjusted audio as an HDCD player would. This gives 20-bit FLAC (about 5% larger) and Apple Lossless (~30% larger) files. Decode makes the audio ~6 dB quieter, but ReplayGain makes up the difference. Keep as pressed keeps the original data (peaks compressed). An HDCD disc whose codes ask for nothing is always kept as pressed."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Pre-emphasis") {
                Picker("Tracks with pre-emphasis", selection: $model.settings.preEmphasis) {
                    Text("Ask each time").tag(PreEmphasisChoice.ask)
                    Text("De-emphasize").tag(PreEmphasisChoice.deEmphasize)
                    Text("Keep as pressed").tag(PreEmphasisChoice.keep)
                }
                Text(
                    "A few old CDs were mastered with pre-emphasis, a treble boost that a CD player reverses on playback. De-emphasize removes the treble boost, as a CD player does, so the recording sounds as the artist intended. Many ripping or player apps ignore this. The de-emphasized files are 20-bit FLAC and Apple Lossless, tagged DE_EMPHASIZED=yes. Keep as pressed gives bit-for-bit copies of the disc (treble boosted), tagged PRE_EMPHASIS=yes.\n\nA disc image always keeps the disc as pressed."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Silent tracks") {
                Picker("Tracks that are all digital silence", selection: $model.settings.silentTracks) {
                    Text("Ask each time").tag(SilentTrackChoice.ask)
                    Text("Leave out").tag(SilentTrackChoice.leaveOut)
                    Text("Keep").tag(SilentTrackChoice.keep)
                }
                Text(
                    "Some discs have many short tracks of digital silence, to put hidden songs at a high track number. Leave out writes no files for them; the other tracks keep the disc's numbers. The rip always has every track, so AccurateRip and CTDB check the whole disc, and a disc image keeps them."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("DTS-CD") {
                Picker("Discs whose tracks hold a DTS stream", selection: $model.settings.dts) {
                    Text("Ask each time").tag(DTSChoice.ask)
                    Text("Album and a decoded copy").tag(DTSChoice.decode)
                    Text("Decoded album only").tag(DTSChoice.decodeOnly)
                    Text("DTS stream only").tag(DTSChoice.keep)
                }
                Text(
                    "A DTS-CD holds surround sound coded as DTS, which plays as loud static except through a DTS decoder or receiver. Silverside decodes it with ffmpeg into files with every channel (20-bit FLAC or Apple Lossless, AAC, or AIFF), tagged DTS=decoded. The DTS stream as the disc has it needs a lossless format."
                )
                .font(.caption).foregroundStyle(.secondary)
                LabeledContent("ffmpeg") {
                    Text(ffmpeg.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Not found")
                        .foregroundStyle(ffmpeg == nil ? .orange : .secondary)
                }
                if ffmpeg == nil {
                    Text("To decode DTS, install ffmpeg. In Terminal: brew install ffmpeg")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section("Disc image") {
                Toggle("Also write a disc image", isOn: $model.settings.writeImages)
                FolderField(label: "Images", path: $model.settings.images)
                    .disabled(!model.settings.writeImages)
                Text(
                    "The whole disc in one lossless file (FLAC when the library is AAC or MP3), with a CUE sheet from which a burner can make the disc again. It is in addition to the album's tracks, in folders named as the library's. Data tracks and CD+G graphics are not in it."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .watchingForLAME($lame)
        .task {
            // ffmpeg too, so that an install in Terminal shows here at once.
            while !Task.isCancelled {
                let found = FFmpeg.program()
                if found != ffmpeg { ffmpeg = found }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder private var aacOptions: some View {
        @Bindable var model = model
        Picker("Mode", selection: $model.settings.aac.mode) {
            ForEach(AACOptions.Mode.allCases, id: \.self) { Text(Self.name(of: $0)).tag($0) }
        }
        if model.settings.aac.mode == .vbr {
            Picker("Quality", selection: $model.settings.aac.vbrQuality) {
                ForEach(Self.aacQualities, id: \.value) { Text($0.name).tag($0.value) }
                if !Self.aacQualities.contains(where: { $0.value == model.settings.aac.vbrQuality }) {
                    Text("Custom (\(model.settings.aac.vbrQuality))").tag(model.settings.aac.vbrQuality)
                }
            }
            Text("A true VBR takes its size from the quality alone; the bit rate is not used.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Picker("Bit rate", selection: $model.settings.aac.bitRate) {
                ForEach(Self.bitRates, id: \.self) { Text("\($0) kbit/s").tag($0) }
                if !Self.bitRates.contains(model.settings.aac.bitRate) {
                    Text("\(model.settings.aac.bitRate) kbit/s").tag(model.settings.aac.bitRate)
                }
            }
            Text(
                model.settings.aac.mode == .vbrConstrained
                    ? "Apple's choice for iTunes Plus: the bit rate varies around this target. 256 is the usual."
                    : "The bit rate everywhere, or on average over the track."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        Text("Advanced Audio Coding, Apple's preferred format for compressed audio. Most other systems play it too.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var mp3Options: some View {
        @Bindable var model = model
        LabeledContent("lame") {
            if let lame {
                Text("Found at \(lame.path)").foregroundStyle(Theme.good)
            } else {
                Text("Not found. Install it with `brew install lame`.").foregroundStyle(Theme.warning)
            }
        }
        // The options do nothing until lame is found.
        Group {
            Picker("Mode", selection: $model.settings.mp3.mode) {
                ForEach(MP3Options.Mode.allCases, id: \.self) { Text(Self.name(of: $0)).tag($0) }
            }
            if model.settings.mp3.mode == .vbr {
                Picker("Quality", selection: $model.settings.mp3.vbrQuality) {
                    ForEach(0...9, id: \.self) { Text(Self.mp3Quality($0)).tag($0) }
                }
            } else {
                Picker("Bit rate", selection: $model.settings.mp3.bitRate) {
                    ForEach(Self.bitRates, id: \.self) { Text("\($0) kbit/s").tag($0) }
                    if !Self.bitRates.contains(model.settings.mp3.bitRate) {
                        Text("\(model.settings.mp3.bitRate) kbit/s").tag(model.settings.mp3.bitRate)
                    }
                }
            }
        }
        .disabled(lame == nil)
        Text("Silverside runs the \"lame\" MP3 encoder as an external program.")
            .font(.caption).foregroundStyle(.secondary)
    }

    static func name(of mode: AACOptions.Mode) -> String {
        switch mode {
        case .cbr: "Constant bit rate (CBR)"
        case .abr: "Average bit rate (ABR)"
        case .vbrConstrained: "Constrained VBR"
        case .vbr: "Variable bit rate (VBR)"
        }
    }

    static func name(of mode: MP3Options.Mode) -> String {
        switch mode {
        case .vbr: "Variable bit rate (VBR)"
        case .cbr: "Constant bit rate (CBR)"
        case .abr: "Average bit rate (ABR)"
        }
    }

    static let bitRates = [128, 160, 192, 224, 256, 320]

    /// Apple's VBR quality runs from 0 to 127; these are the steps worth naming.
    static let aacQualities: [(name: String, value: Int)] = [
        ("Low (32)", 32), ("Medium (64)", 64), ("High (96)", 96), ("Highest (127)", 127),
    ]

    static func mp3Quality(_ value: Int) -> String {
        switch value {
        case 0: "0 · best, about 245 kbit/s"
        case 2: "2 · about 190 kbit/s"
        case 4: "4 · about 165 kbit/s"
        case 6: "6 · about 130 kbit/s"
        case 9: "9 · smallest, about 65 kbit/s"
        default: String(value)
        }
    }
}

struct NamingSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("In the library") {
                TextField("Album folder", text: $model.settings.folderTemplate)
                TextField("Track file", text: $model.settings.trackTemplate)
                Text(
                    "Fields: {artist} {albumArtist} {album} {year} {date} {disc} {discs} {discTitle} {track} {title} {trackArtist} {otherArtist}. A part in [brackets] is left out when its field is empty."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Example") {
                let example = NamingExample(model: model)
                LabeledContent("Library file") { Text(example.libraryPath).textSelection(.enabled) }
                LabeledContent("Title tag") { Text(example.titleTag).textSelection(.enabled) }
                LabeledContent("Rip folder") { Text(example.ripFolder).textSelection(.enabled) }
                Text(example.source).font(.caption).foregroundStyle(.secondary)
            }
            Section("Rips") {
                TextField("Rip folder", text: $model.settings.ripFolderTemplate)
            }
            Section("Style") {
                Toggle(
                    "Live shows: add [Venue, date] to titles, and take the date from the disc",
                    isOn: $model.settings.liveShowStyle)
                Picker("Segue marks (a title's trailing \">\")", selection: $model.settings.segueMarks) {
                    Text("In tags only, not in file names").tag(SegueMarks.tagsOnly)
                    Text("In tags and file names").tag(SegueMarks.everywhere)
                    Text("Removed").tag(SegueMarks.none)
                }
                TextField(
                    "Compilations folder", text: $model.settings.compilationFolder, prompt: Text("Various Artists"))
                Text(
                    "A compilation is a release credited to Various Artists. Its files are tagged COMPILATION, and each track's name carries its own artist through {otherArtist}. The folder takes this name in place of the album artist."
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle(
                    "Plain punctuation: ASCII quotes and dashes in names and tags",
                    isOn: $model.settings.plainPunctuation)
            }
        }
        .formStyle(.grouped)
    }
}

/// The names the templates give, for the disc in the selected drive, or for a sample disc.
struct NamingExample {
    var libraryPath: String
    var titleTag: String
    var ripFolder: String
    var source: String

    init(model: AppModel) {
        let settings = model.settings
        let disc = model.selectedDrive?.disc ?? model.drives.lazy.compactMap(\.disc).first
        let release: MusicBrainzRelease
        let medium: MusicBrainzRelease.Medium
        let track: MusicBrainzRelease.Track
        if let disc, let shown = disc.shownRelease, let found = disc.shownMedium, found.tracks.count > 2 {
            release = shown
            medium = found
            track = found.tracks[2]
            source = "From the disc in \(model.selectedDrive?.name ?? "the drive")."
        } else {
            release = Self.sample
            medium = release.media[0]
            track = medium.tracks[2]
            source = "A sample disc; insert one to see its names."
        }
        let metadata = TrackMetadata(
            release: release, medium: medium, track: track, liveShowStyle: settings.liveShowStyle,
            plainPunctuation: settings.plainPunctuation, segueMarks: settings.segueMarks,
            compilationFolder: settings.compilationFolder)
        let values = metadata.nameValues
        titleTag = metadata.title
        libraryPath =
            NameTemplate(settings.folderTemplate).name(values) + "/" + NameTemplate(settings.trackTemplate).name(values)
            + "." + settings.format.fileExtension
        ripFolder = NameTemplate(settings.ripFolderTemplate).name(NameTemplate.values(release: release, medium: medium))
    }

    /// *Clarity of Cal*, with a guest on track 3, and a segue mark on it.
    static let sample: MusicBrainzRelease = {
        let vulfpeck = MusicBrainzRelease.Credit(name: "Vulfpeck", artistID: "sample")
        var release = MusicBrainzRelease.manual(
            toc: try! TOC(audioTrackStarts: [0, 14_000, 32_000], leadOutLBA: 52_000))
        release.title = "Clarity of Cal"
        release.artistCredit = [vulfpeck]
        release.date = "2025-03-04"
        for (index, title) in ["Big Dipper", "Matter of Time", "Can You Tell >"].enumerated() {
            release.media[0].tracks[index].title = title
            release.media[0].tracks[index].artistCredit = [vulfpeck]
        }
        release.media[0].tracks[2].artistCredit = [
            MusicBrainzRelease.Credit(name: "Vulfpeck", joinPhrase: " & ", artistID: "sample"),
            .init(name: "Joey Dosik"),
        ]
        return release
    }()
}
