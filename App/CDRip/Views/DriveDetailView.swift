import CDRipDarwin
import CDRipKit
import SwiftUI

/// A drive's disc: the album, the tracks, and the rip's progress, with the toolbar.
struct DriveDetailView: View {
    @Environment(AppModel.self) private var model
    @Bindable var slot: DriveSlot
    @State private var releasePickerShown = false

    var body: some View {
        Group {
            switch slot.discState {
            case .empty:
                NoDiscView(driveName: slot.name)
            case .reading:
                ProgressView("Reading the disc...")
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
            .help("Eject the disc")
            .disabled(slot.device.discBSDName == nil || isRipping)

            Button {
                slot.lookUpAgain()
            } label: {
                Label("Look Up Metadata", systemImage: "magnifyingglass").padding(.horizontal, 4)
            }
            .help("Ask MusicBrainz about this disc again")
            .disabled(slot.disc == nil || isRipping)
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
        if isRipping {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.stopRip(slot)
                } label: {
                    Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon)
                }
                .help("Stop after the read under way. The tracks ripped so far stay.")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.startRip(slot)
            } label: {
                Label(ripTitle, systemImage: "arrow.down.circle.fill").labelStyle(.titleAndIcon)
                    .padding(.trailing, 6)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(slot.disc == nil || isRipping || slot.selectedTracks.isEmpty)
        }
    }

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
                AlbumHeader(disc: disc, releasePickerShown: $releasePickerShown, source: $slot.namesSource)
                    .padding(16)
            }
            if let rip = slot.rip, !rip.isRunning, let report = rip.report {
                ResultBanner(rip: rip, report: report, folder: rip.folder)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            Divider()
            TrackTable(slot: slot)
            Divider()
            StatusBar(slot: slot)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }
}

struct AlbumHeader: View {
    @Environment(AppModel.self) private var model
    var disc: DiscInfo
    @Binding var releasePickerShown: Bool
    @Binding var source: DiscInfo.Source

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverView(data: disc.cover)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 16) {
                    Field(label: "Album", value: disc.title(from: source))
                    Field(label: disc.yearIsFirstRelease ? "First Release" : "Year", value: disc.year ?? "—")
                        .frame(width: 120)
                        .help(
                            disc.yearIsFirstRelease
                                ? "This edition has no date in MusicBrainz. The year is the release group's first release."
                                : "")
                }
                HStack(alignment: .top, spacing: 16) {
                    Field(
                        label: "Album Artist",
                        value: disc.artist(from: source).isEmpty ? "—" : disc.artist(from: source))
                    Field(
                        label: "Tracks",
                        value: "\(disc.toc.audioTracks.count) · \(Format.duration(sectors: disc.totalSectors))"
                    )
                    .frame(width: 120)
                }
                HStack(spacing: 8) {
                    if disc.hasCDText, disc.release != nil {
                        Picker("Names", selection: $source) {
                            Text("MusicBrainz").tag(DiscInfo.Source.musicBrainz)
                            Text("CD-Text").tag(DiscInfo.Source.cdText)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .help(
                            "Show the names from MusicBrainz, or the CD-Text on the disc. The rip's tags come from MusicBrainz."
                        )
                    } else if disc.hasCDText {
                        Chip(text: "CD-Text on the disc", systemImage: "text.quote")
                    }
                    lookupChip
                    if let label = disc.labelText { Chip(text: label) }
                    if let discLabel = disc.discLabel { Chip(text: discLabel) }
                    if let mcn = disc.mcn { Chip(text: "MCN \(mcn)") }
                    Spacer()
                    if disc.releases.count > 1 {
                        Button(
                            disc.isAmbiguous ? "Choose Release..." : "Other Releases (\(disc.releases.count - 1))..."
                        ) {
                            releasePickerShown = true
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder private var lookupChip: some View {
        switch disc.lookup {
        case .notLookedUp:
            Chip(text: "MusicBrainz · not looked up", systemImage: "minus")
        case .lookingUp:
            Chip(text: "MusicBrainz · looking up...", systemImage: "ellipsis")
        case .found where disc.isAmbiguous:
            Chip(text: "MusicBrainz · several releases match", tone: .warning, systemImage: "questionmark")
        case .found where disc.isFuzzy:
            Chip(text: "MusicBrainz · nearly the same TOC", tone: .warning, systemImage: "approximatelyequal")
        case .found:
            Chip(text: "MusicBrainz · Disc ID match", tone: .good, systemImage: "checkmark")
        case .notFound:
            Chip(text: "Not in MusicBrainz", tone: .warning, systemImage: "xmark")
        case .failed:
            Chip(text: "MusicBrainz · lookup failed", tone: .bad, systemImage: "wifi.slash")
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
                Text(statusText).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                Text(timeText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                HStack(spacing: 10) {
                    Text(slot.fastMode ? "Fast" : "Secure")
                    if let offset = slot.rip?.readOffset { Text("Offset \(offset.signedDescription)") }
                    Text(model.settings.encodeAfterRip ? model.settings.format.rawValue.uppercased() : "WAV")
                    Button("Show Log") { model.logShown = true }
                        .buttonStyle(.link)
                        .disabled(slot.rip == nil)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
            }
            if let rip = slot.rip, rip.phase != .stopped {
                SheenProgressBar(
                    fraction: rip.phase == .finished ? 1 : rip.fraction, verified: rip.report?.isVerified == true)
                if let track = rip.currentTrack, let errors = rip.trackErrors[track], !errors.isEmpty {
                    TrackErrorStrip(errors: errors)
                }
            }
        }
    }

    private var statusText: String {
        if let rip = slot.rip { return rip.statusText }
        guard let disc = slot.disc else { return "" }
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
        if let left = rip.secondsLeft { text += " · " + Format.timeLeft(seconds: left) }
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
                HStack(spacing: 6) {
                    ForEach(ResultChips.chips(for: report), id: \.text) { $0 }
                }
            }
            Spacer()
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

/// The chips that sum up a report: AccurateRip, CTDB, re-reads, repairs.
enum ResultChips {
    static func chips(for report: RipReport) -> [Chip] {
        var chips = [Chip]()
        let accurate = report.tracks.filter { $0.accurateRip == .accurate }.count
        let others = report.tracks.filter { $0.accurateRip == .otherPressings }.count
        let total = report.tracks.count
        if report.tracks.allSatisfy({ $0.accurateRip == .notInDatabase }) {
            chips.append(Chip(text: "Not in AccurateRip"))
        } else {
            chips.append(Chip(text: "AccurateRip \(accurate) / \(total)", tone: accurate == total ? .good : .warning))
            if others > 0 { chips.append(Chip(text: "\(others) match other pressings", tone: .good)) }
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
        if suspects > 0 { chips.append(Chip(text: "\(suspects) sectors re-read", tone: .warning)) }
        let repaired = report.tracks.reduce(0) { $0 + $1.repairedSamples }
        if repaired > 0 { chips.append(Chip(text: "\(repaired) samples repaired", tone: .warning)) }
        let unresolved = report.tracks.reduce(0) { $0 + $1.unresolvedSectors.count }
        if unresolved > 0 { chips.append(Chip(text: "\(unresolved) sectors unresolved", tone: .bad)) }
        return chips
    }
}
