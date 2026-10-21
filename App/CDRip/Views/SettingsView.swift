import AppKit
import CDRipDarwin
import CDRipKit
import SwiftUI

/// The settings window. Every setting is in the file that `cdrip config` shares.
struct SettingsView: View {
    enum Tab: String { case general, drives, ripping, encoding, naming }
    @State private var tab = Tab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "slider.horizontal.3") }.tag(Tab.general)
            DriveSettings().tabItem { Label("Drives", systemImage: "opticaldiscdrive") }.tag(Tab.drives)
            RippingSettings().tabItem { Label("Ripping", systemImage: "arrow.down.circle") }.tag(Tab.ripping)
            EncodingSettings().tabItem { Label("Encoding", systemImage: "waveform") }.tag(Tab.encoding)
            NamingSettings().tabItem { Label("Naming", systemImage: "textformat") }.tag(Tab.naming)
        }
        .frame(width: 640, height: 520)
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
                TextField("", text: $path).labelsHidden()
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
        HSplitView {
            List(profiles, id: \.key, selection: $selectedKey) { profile in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(profile.vendor) \(profile.product)")
                    Text(offsetSummary(profile)).font(.caption).foregroundStyle(.secondary)
                }
                .tag(profile.key)
            }
            .frame(minWidth: 200, idealWidth: 220)
            Group {
                if let profile = profiles.first(where: { $0.key == selectedKey }) {
                    details(profile)
                } else {
                    Text("Select a drive").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 320)
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
                        TextField("", text: $manualOffset).labelsHidden().frame(width: 80).multilineTextAlignment(
                            .trailing)
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
                    LabeledContent(observation.disc) {
                        Text(observation.offsets.map(\.signedDescription).joined(separator: ", "))
                    }
                }
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

    var body: some View {
        @Bindable var model = model
        Form {
            Section("AAC") {
                Picker("Mode", selection: $model.settings.aac.mode) {
                    ForEach(AACOptions.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Stepper(
                    "Bit rate: \(model.settings.aac.bitRate) kbit/s", value: $model.settings.aac.bitRate, in: 64...320,
                    step: 16)
                Stepper(
                    "VBR quality: \(model.settings.aac.vbrQuality)", value: $model.settings.aac.vbrQuality, in: 0...127)
            }
            Section("MP3") {
                Picker("Mode", selection: $model.settings.mp3.mode) {
                    ForEach(MP3Options.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Stepper(
                    "VBR quality: \(model.settings.mp3.vbrQuality) (0 is best)", value: $model.settings.mp3.vbrQuality,
                    in: 0...9)
                Stepper(
                    "Bit rate: \(model.settings.mp3.bitRate) kbit/s", value: $model.settings.mp3.bitRate, in: 64...320,
                    step: 16)
                Text("MP3 needs the lame program on the Mac. CDRip runs it as a separate program.")
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
