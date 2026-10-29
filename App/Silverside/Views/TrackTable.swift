import SilversideKit
import SwiftUI

/// The tracks of the disc, with their rip status.
struct TrackTable: View {
    @Environment(AppModel.self) private var model
    @Bindable var slot: DriveSlot
    @State private var tableSelection: Set<Int> = []
    /// Tracks whose artist field is open although the track has no artist of its own yet.
    @State private var artistRows: Set<Int> = []
    /// The track field being edited, for Tab to go to the next.
    @FocusState private var focusedName: NameField?
    @AppStorage("driveTrackColumns") private var columns = TableColumnCustomization<DiscInfo.Track>()
    @AppStorage("ripTrackColumns") private var ripColumns = TableColumnCustomization<RipReport.Track>()

    private var rows: [DiscInfo.Track] { slot.disc?.tracks(from: slot.namesSource) ?? [] }

    var body: some View {
        // Before a rip, the result columns would hold only dashes, so the titles get the room.
        if let rip = slot.rip {
            Table(rows, selection: $tableSelection, columnCustomization: $columns) {
                discColumns
                TableColumn("Status") { track in
                    StatusCell(
                        state: rip.trackStates[track.number], ctdb: rip.ctdb, summary: rip.summaries[track.number],
                        showsRereads: columns[visibility: TrackColumns.rereads] != .visible)
                }
                .width(min: 150, ideal: 200)
                .customizationID("status")
                .disabledCustomizationBehavior(.visibility)
                TableColumn("Re-reads") { track in
                    if case .finished(let report)? = rip.trackStates[track.number] {
                        RereadsCell(track: report, ctdb: rip.ctdb)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                .width(min: 80, ideal: 100)
                .customizationID(TrackColumns.rereads)
                .defaultVisibility(.hidden)
                TableColumn("AccurateRip") { track in
                    AccurateRipCell(state: rip.trackStates[track.number])
                }
                .width(min: 90, ideal: 110)
                .customizationID("accurateRip")
                TableColumn("CTDB") { track in
                    CTDBCell(run: rip, number: track.number)
                }
                .width(min: 70, ideal: 90)
                .customizationID("ctdb")
                if rip.encodes {
                    TableColumn("Encoding") { track in
                        EncodeCell(state: rip.encodeStates[track.number], format: rip.encodingFormat)
                    }
                    .width(min: 80, ideal: 100)
                    .customizationID("encoding")
                }
            }
            .alternatingRowBackgrounds(.disabled)
            .onChange(of: columns) { TrackColumns.copyVisibility(from: columns, to: &ripColumns) }
        } else {
            Table(rows, selection: $tableSelection) {
                discColumns
            }
            .alternatingRowBackgrounds(.disabled)
        }
    }

    /// The columns of the disc itself: the checkbox, the number, the title, and the time.
    @TableColumnBuilder<DiscInfo.Track, Never> private var discColumns: some TableColumnContent<DiscInfo.Track, Never> {
        TableColumn("") { track in
            Toggle("", isOn: binding(for: track.number))
                .labelsHidden()
                .disabled(slot.rip?.isRunning == true)
        }
        .width(24)
        .customizationID("include")
        .disabledCustomizationBehavior(.all)
        TableColumn("") { track in
            PlayButton(player: model.player, source: .disc(slotID: slot.id, track: track.number), isEnabled: canPlay) {
                guard let disc = slot.disc,
                    let tocTrack = disc.toc.audioTracks.first(where: { $0.number == track.number })
                else { return }
                model.player.play(
                    disc: slot, track: tocTrack, title: track.title,
                    subtitle: track.artist ?? disc.shownRelease?.artist ?? slot.name)
            }
        }
        .width(22)
        .customizationID("play")
        .disabledCustomizationBehavior(.all)
        TableColumn("#") { track in
            Text(String(track.number)).foregroundStyle(.secondary).monospacedDigit()
        }
        .width(28)
        .customizationID("number")
        .disabledCustomizationBehavior(.all)
        TableColumn("Title") { track in
            VStack(alignment: .leading, spacing: 1) {
                if canEdit {
                    let title = title(of: track.number, shown: track.title)
                    NameTextField(
                        value: title.wrappedValue, field: .title(track.number), focus: $focusedName,
                        tabOrder: { fieldOrder }, pending: slot.pendingNames
                    ) { title.wrappedValue = $0 }
                    // The artist's field shows when the track has an artist of its own, or on request.
                    if track.artist != nil || artistRows.contains(track.number) {
                        let artist = artist(of: track.number)
                        NameTextField(
                            value: artist.wrappedValue, prompt: "Track artist", field: .artist(track.number),
                            focus: $focusedName, tabOrder: { fieldOrder }, pending: slot.pendingNames
                        ) { artist.wrappedValue = $0 }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text(track.title)
                    if let artist = track.artist { Text(artist).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .contextMenu {
                if canEdit {
                    if track.artist == nil && !artistRows.contains(track.number) {
                        Button("Add Track Artist") { artistRows.insert(track.number) }
                    }
                    Button("Clear This Track's Edits") {
                        slot.disc?.edits.setTitle(nil, ofTrack: track.number)
                        slot.disc?.edits.setArtist(nil, ofTrack: track.number)
                        artistRows.remove(track.number)
                    }
                    .disabled(slot.disc?.edits.tracks[track.number] == nil)
                }
            }
        }
        .width(min: 220, ideal: 360)
        .customizationID("title")
        .disabledCustomizationBehavior(.visibility)
        TableColumn("Time") { track in
            Text(track.duration).monospacedDigit().foregroundStyle(.secondary)
        }
        .width(52)
        .customizationID("time")
        .disabledCustomizationBehavior(.visibility)
        TableColumn("") { track in
            if let disc = slot.disc {
                InfoButton(help: "Track info", debugID: "track\(track.number)") { InfoSection.track(track, disc: disc) }
            }
        }
        .width(22)
        .customizationID("info")
        .disabledCustomizationBehavior(.all)
    }

    /// A track plays while the drive is free: not during a rip, a repair, or a drive test.
    private var canPlay: Bool { slot.disc != nil && slot.rip?.isRunning != true && !slot.isBusy }

    /// Titles are editable from the MusicBrainz names (or the typed-in ones), not while a rip runs.
    private var canEdit: Bool {
        slot.rip?.isRunning != true && slot.namesSource == .musicBrainz && slot.disc?.baseRelease != nil
    }

    /// The track fields in Tab's order.
    private var fieldOrder: [NameField] {
        let rows = rows
        return NameField.trackOrder(rows.map(\.number)) { number in
            rows.first { $0.number == number }?.artist != nil || artistRows.contains(number)
        }
    }

    /// A binding to a track's title edit: the original title clears the edit.
    private func title(of number: Int, shown: String) -> Binding<String> {
        Binding(
            get: { slot.disc.flatMap { $0.edits.tracks[number]?.title ?? $0.baseTitle(ofTrack: number) } ?? shown },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                let original = slot.disc?.baseTitle(ofTrack: number)
                slot.disc?.edits.setTitle(trimmed.isEmpty || trimmed == original ? nil : trimmed, ofTrack: number)
            })
    }

    /// A binding to a track's artist edit: empty, or the release's own artist, clears the edit.
    private func artist(of number: Int) -> Binding<String> {
        Binding(
            get: {
                guard let disc = slot.disc else { return "" }
                if let edited = disc.edits.tracks[number]?.artist { return edited }
                // The release's artist for the track, when it is not the album's.
                let artist = disc.baseArtist(ofTrack: number)
                return artist != disc.shownRelease?.artist ? artist ?? "" : ""
            },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                let original = slot.disc?.baseArtist(ofTrack: number)
                slot.disc?.edits.setArtist(trimmed.isEmpty || trimmed == original ? nil : trimmed, ofTrack: number)
            })
    }

    private func binding(for number: Int) -> Binding<Bool> {
        Binding(
            get: { slot.selectedTracks.contains(number) },
            set: { if $0 { slot.selectedTracks.insert(number) } else { slot.selectedTracks.remove(number) } })
    }
}

/// The track tables' columns that can be shown and hidden from the header's menu. A choice in
/// a drive's table holds in an earlier rip's table too, and the other way round.
enum TrackColumns {
    static let rereads = "rereads"
    static let optional = [rereads, "accurateRip", "ctdb", "encoding"]

    static func copyVisibility<Source, Target>(
        from source: TableColumnCustomization<Source>, to target: inout TableColumnCustomization<Target>
    ) {
        for id in optional where target[visibility: id] != source[visibility: id] {
            target[visibility: id] = source[visibility: id]
        }
    }
}

struct StatusCell: View {
    var state: RipRun.TrackState?
    var ctdb: RipReport.CTDBResult?
    var summary: String?
    var showsRereads = false

    var body: some View {
        switch state {
        case nil:
            Text("Ready").foregroundStyle(.secondary)
        case .queued:
            Text("Queued").foregroundStyle(.secondary)
        case .skipped:
            Text("—").foregroundStyle(.secondary)
        case .reading(let pass, let passes, let fraction):
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(pass == 1 ? "Reading" : "Read \(pass) of up to \(passes)").font(.callout)
                    Spacer()
                    Text("\(Int(fraction * 100))%").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                SheenProgressBar(fraction: fraction)
            }
        case .rereading(let round, let maximum, let suspects):
            Label(
                "Re-reading \(Format.count(suspects, "sector")) · round \(round) of \(maximum)",
                systemImage: "arrow.clockwise"
            )
            .foregroundStyle(Theme.warning)
        case .testing(let fraction):
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Test read").font(.callout)
                    Spacer()
                    Text("\(Int(fraction * 100))%").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                SheenProgressBar(fraction: fraction)
            }
        case .finished(let track):
            FinishedStatus(track: track, ctdb: ctdb, summary: summary, showsRereads: showsRereads)
        }
    }
}

/// What a finished track came to, in one word: the rule the design asks for, red only when
/// a database said no or reads never agreed and nothing proved the track.
enum TrackVerdict {
    case verified
    case repaired
    /// Read the same each time, but no database can check it.
    case copied
    case notVerified

    init(_ track: RipReport.Track, ctdb: RipReport.CTDBResult?) {
        let wholeDisc = ctdb?.status == .verified || ctdb?.status == .repaired
        let proved =
            track.accurateRip == .accurate || track.accurateRip == .otherPressings || (track.ctdbConfidence ?? 0) > 0
            || wholeDisc
        if proved {
            self = track.repairedSamples > 0 ? .repaired : .verified
        } else if track.accurateRip == .notAccurate || !track.unresolvedSectors.isEmpty
            || ctdb?.status == .notVerified || ctdb?.status == .partlyRepaired
        {
            self = .notVerified
        } else {
            self = .copied
        }
    }

    var text: String {
        switch self {
        case .verified: "Verified"
        case .repaired: "Repaired"
        case .copied: "Copied"
        case .notVerified: "Not verified"
        }
    }

    var icon: String {
        switch self {
        case .verified: "checkmark.circle"
        case .repaired: "checkmark.circle.badge.questionmark"
        case .copied: "checkmark"
        case .notVerified: "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .verified: Theme.good
        case .repaired: Theme.warning
        case .copied: .secondary
        case .notVerified: Theme.bad
        }
    }
}

struct FinishedStatus: View {
    var track: RipReport.Track
    var ctdb: RipReport.CTDBResult?
    var summary: String?
    /// Re-reads go under the verdict while the table's Re-reads column is hidden.
    var showsRereads = false

    var body: some View {
        let verdict = TrackVerdict(track, ctdb: ctdb)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: verdict.icon).foregroundStyle(verdict.color)
                Text(verdict.text).foregroundStyle(verdict.color)
            }
            if let note {
                // Re-reads that ended in a verified track are routine, so only a repair or a failure gets a color.
                Text(note).font(.caption).foregroundStyle(
                    verdict == .verified ? AnyShapeStyle(.secondary) : AnyShapeStyle(verdict.color))
            }
        }
        .help(summary ?? help(for: verdict))
    }

    /// What the track needed, under its verdict: the samples CTDB repaired, and the re-reads.
    private var note: String? {
        var parts = [String]()
        if showsRereads {
            let rereads = track.suspectSectors.count
            let unreadable = track.unreadableSectors?.count ?? 0
            if rereads > 0 { parts.append(Format.count(rereads, "sector") + " re-read") }
            if unreadable > 0 { parts.append("\(unreadable) unreadable") }
        }
        if track.repairedSamples > 0 {
            parts.append(
                track.repairedSamples.formatted() + (track.repairedSamples == 1 ? " sample" : " samples") + " repaired")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func help(for verdict: TrackVerdict) -> String {
        switch verdict {
        case .verified: "The track matches AccurateRip or the CUETools database."
        case .repaired: "CTDB's repair data corrected the track, and the result is verified."
        case .copied: "The reads agree, but no database has this disc to check against."
        case .notVerified: "No database matches the track, and a repair was not possible."
        }
    }
}

/// How many sectors were re-read, as a table cell.
struct RereadsCell: View {
    var track: RipReport.Track
    var ctdb: RipReport.CTDBResult?

    var body: some View {
        let count = track.suspectSectors.count
        let unreadable = track.unreadableSectors?.count ?? 0
        if count == 0 && unreadable == 0 {
            Text("—").foregroundStyle(.secondary)
        } else {
            Text(count > 0 ? Format.count(count, "sector") : "\(unreadable) unreadable")
                .foregroundStyle(TrackVerdict(track, ctdb: ctdb) == .notVerified ? Theme.bad : Theme.warning)
                .help(
                    "\(Format.count(count, "sector")) read differently and were re-read"
                        + (track.rereadRounds > 0 ? " in \(Format.count(track.rereadRounds, "round"))" : "")
                        + (unreadable > 0 ? "; \(unreadable) could not be read" : "")
                        + (track.unresolvedSectors.isEmpty
                            ? "." : "; \(track.unresolvedSectors.count) never agreed."))
        }
    }
}

/// A result that is good: a check mark and plain text. Green is for the verdict alone, so a
/// table of good results stays quiet, and color marks the tracks that need a look.
struct CheckedText: View {
    var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark").foregroundStyle(.secondary)
            Text(text).monospacedDigit()
        }
    }
}

struct AccurateRipCell: View {
    var state: RipRun.TrackState?

    var body: some View {
        switch state {
        case .finished(let track):
            switch track.accurateRip {
            case .accurate:
                let confidence = track.accurateRipConfidence.map { max($0[0], $0[1]) } ?? 0
                CheckedText(text: String(confidence))
                    .help(
                        "Accurate: \(confidence) rips in AccurateRip have this track's checksum, at this pressing's offset (the larger of the v1 and v2 counts). AccurateRip stops counting at 200."
                    )
            case .otherPressings:
                CheckedText(text: "Other pressing")
                    .help("Matches AccurateRip at other offsets only, so it is free of errors.")
            case .notAccurate:
                Text("Not accurate").foregroundStyle(Theme.bad)
            case .notInDatabase:
                Text("Not in database").foregroundStyle(.secondary)
            case .noChecksum:
                Text("No checksum").foregroundStyle(.secondary)
                    .help(
                        "AccurateRip has this disc, but no checksum for this track, so it cannot check it. It keeps none for a track that is all silence."
                    )
            }
        case .reading, .rereading:
            Text("Pending").foregroundStyle(.secondary)
        default:
            Text("—").foregroundStyle(.secondary)
        }
    }
}

struct CTDBCell: View {
    var run: RipRun?
    var number: Int

    var body: some View {
        if let run, case .finished(let track) = run.trackStates[number] {
            CTDBResultCell(track: track, ctdb: run.ctdb, isRunning: run.isRunning)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}

/// A finished track's CTDB result: its own confidence, or the disc's result once the rip has one.
struct CTDBResultCell: View {
    var track: RipReport.Track
    var ctdb: RipReport.CTDBResult?
    var isRunning = false

    var body: some View {
        if let confidence = track.ctdbConfidence, confidence > 0 {
            CheckedText(text: String(confidence))
                .help("Verified: \(confidence) rips in the CUETools database have this track's checksum.")
        } else if let ctdb {
            switch ctdb.status {
            case .verified, .repaired: CheckedText(text: "Verified")
            case .partlyRepaired, .notVerified: Text("Not verified").foregroundStyle(Theme.bad)
            case .notInDatabase: Text("Not in database").foregroundStyle(.secondary)
            case .notChecked: Text("Not checked").foregroundStyle(.secondary)
            }
        } else if isRunning {
            Text("Pending").foregroundStyle(.secondary)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}

struct EncodeCell: View {
    var state: RipRun.EncodeState?
    var format: AudioFormat?

    var body: some View {
        switch state {
        case .queued:
            Text("Queued").foregroundStyle(.secondary)
        case .encoding:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Encoding")
            }
        case .encoded(let file):
            CheckedText(text: format?.rawValue.uppercased() ?? "Encoded").help(file.path)
        case .notEncoded:
            Text("Not encoded").foregroundStyle(.secondary)
        case .failed:
            Text("Failed").foregroundStyle(Theme.bad)
        case nil:
            Text("—").foregroundStyle(.secondary)
        }
    }
}
