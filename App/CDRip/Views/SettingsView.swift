import AppKit
import CDRipDarwin
import CDRipKit
import SwiftUI

/// The settings window. Every setting is in the file that `cdrip config` shares.
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
                    ForEach(AudioFormat.allCases, id: \.self) { Text(formatName($0)).tag($0) }
                }
                .disabled(!model.settings.encodeAfterRip)
                Toggle("Keep the rip's WAV files after encoding", isOn: $model.settings.keepRipAfterEncoding)
                    .disabled(!model.settings.encodeAfterRip)
                Text(
                    "Otherwise a rip whose tracks are all verified and encoded is deleted, and its report goes in the album folder."
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle("Eject the disc if every track is verified", isOn: $model.settings.ejectAfterRip)
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
    }

    private func formatName(_ format: AudioFormat) -> String {
        switch format {
        case .flac: "FLAC"
        case .alac: "Apple Lossless (ALAC)"
        case .aac: "AAC"
        case .aiff: "AIFF"
        case .wav: "WAV"
        case .mp3: "MP3 (needs lame)"
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
                Button("Choose...") {
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

    private var profiles: [DriveProfile] {
        var all = store?.profiles ?? [:]
        for slot in model.drives where !slot.isDemo {
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
        .onAppear { if selectedKey == nil { selectedKey = profiles.first?.key } }
        .onChange(of: selectedKey) { _, key in
            manualOffset = profiles.first { $0.key == key }?.manualOffset.map(String.init) ?? ""
        }
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
                    Text(profile.cacheSectors.map { "\($0) sectors" } ?? "Not measured (cdrip drives --measure-cache)")
                }
                LabeledContent("Flush before a re-read", value: "\(profile.cacheFlushSectors) sectors")
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

struct EncodingSettings: View {
    @Environment(AppModel.self) private var model
    private let lame = MP3Encoder.lame()

    var body: some View {
        @Bindable var model = model
        Form {
            Section("AAC") {
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
            }
            Section("MP3") {
                LabeledContent("lame") {
                    if let lame {
                        Text("Found at \(lame.path)").foregroundStyle(Theme.good)
                    } else {
                        Text("Not found. Install it with `brew install lame`.").foregroundStyle(Theme.warning)
                    }
                }
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
                Text("CDRip runs lame as a separate program, which keeps its LGPL code out of the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Lossless") {
                Text(
                    "FLAC, Apple Lossless, AIFF, and WAV have no options. Every file is decoded again after encoding and must equal the rip."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
                LabeledContent("Rip folder") { Text(example.ripFolder).textSelection(.enabled) }
                Text(example.source).font(.caption).foregroundStyle(.secondary)
            }
            Section("Rips") {
                TextField("Rip folder", text: $model.settings.ripFolderTemplate)
            }
            Section("Style") {
                Toggle("Live-show style: add [Venue, date] to titles", isOn: $model.settings.liveShowStyle)
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
            plainPunctuation: settings.plainPunctuation)
        let values = metadata.nameValues
        libraryPath =
            NameTemplate(settings.folderTemplate).name(values) + "/" + NameTemplate(settings.trackTemplate).name(values)
            + "." + settings.format.fileExtension
        ripFolder = NameTemplate(settings.ripFolderTemplate).name(NameTemplate.values(release: release, medium: medium))
    }

    /// *Clarity of Cal*, with a guest on track 3.
    static let sample: MusicBrainzRelease = {
        let vulfpeck = MusicBrainzRelease.Credit(name: "Vulfpeck", artistID: "sample")
        var release = MusicBrainzRelease.manual(
            toc: try! TOC(audioTrackStarts: [0, 14_000, 32_000], leadOutLBA: 52_000))
        release.title = "Clarity of Cal"
        release.artistCredit = [vulfpeck]
        release.date = "2025-03-04"
        for (index, title) in ["Big Dipper", "Matter of Time", "Can You Tell"].enumerated() {
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
