import CDRipKit
import SwiftUI

/// The tracks of the disc, with their rip status.
struct TrackTable: View {
    @Bindable var slot: DriveSlot
    @State private var tableSelection: Set<Int> = []
    /// Tracks whose artist field is open although the track has no artist of its own yet.
    @State private var artistRows: Set<Int> = []

    private var rows: [DiscInfo.Track] { slot.disc?.tracks(from: slot.namesSource) ?? [] }

    var body: some View {
        // Before a rip, the result columns would hold only dashes, so the titles get the room.
        if let rip = slot.rip {
            Table(rows, selection: $tableSelection) {
                discColumns
                TableColumn("Status") { track in
                    StatusCell(
                        state: rip.trackStates[track.number], ctdb: rip.ctdb, summary: rip.summaries[track.number])
                }
                .width(min: 150, ideal: 200)
                TableColumn("Re-reads") { track in
                    if case .finished(let report)? = rip.trackStates[track.number] {
                        RereadsCell(track: report, ctdb: rip.ctdb)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                .width(min: 80, ideal: 100)
                TableColumn("Repaired") { track in
                    if case .finished(let report)? = rip.trackStates[track.number] {
                        RepairedCell(track: report)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                .width(min: 80, ideal: 110)
                TableColumn("AccurateRip") { track in
                    AccurateRipCell(state: rip.trackStates[track.number])
                }
                .width(min: 110, ideal: 150)
                TableColumn("CTDB") { track in
                    CTDBCell(run: rip, number: track.number)
                }
                .width(min: 70, ideal: 110)
            }
            .alternatingRowBackgrounds(.disabled)
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
        TableColumn("#") { track in
            Text(String(track.number)).foregroundStyle(.secondary).monospacedDigit()
        }
        .width(28)
        TableColumn("Title") { track in
            VStack(alignment: .leading, spacing: 1) {
                if canEdit {
                    TextField("", text: title(of: track.number, shown: track.title))
                        .textFieldStyle(.plain)
                    // The artist's field shows when the track has an artist of its own, or on request.
                    if track.artist != nil || artistRows.contains(track.number) {
                        TextField("", text: artist(of: track.number), prompt: Text("Track artist"))
                            .textFieldStyle(.plain)
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
        TableColumn("Time") { track in
            Text(track.duration).monospacedDigit().foregroundStyle(.secondary)
        }
        .width(52)
    }

    /// Titles are editable from the MusicBrainz names (or the typed-in ones), not while a rip runs.
    private var canEdit: Bool {
        slot.rip?.isRunning != true && slot.namesSource == .musicBrainz && slot.disc?.baseRelease != nil
    }

    /// A binding to a track's title edit: the original title clears the edit.
    private func title(of number: Int, shown: String) -> Binding<String> {
        Binding(
            get: { slot.disc?.tracks(from: .musicBrainz).first { $0.number == number }?.title ?? shown },
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
                return disc.tracks(from: .musicBrainz).first { $0.number == number }?.artist ?? ""
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

struct StatusCell: View {
    var state: RipRun.TrackState?
    var ctdb: RipReport.CTDBResult?
    var summary: String?

    var body: some View {
        switch state {
        case nil:
            Text("Ready").foregroundStyle(.secondary)
        case .queued:
            Text("Queued").foregroundStyle(.secondary)
        case .skipped:
            Text("—").foregroundStyle(.secondary)
        case .reading(let pass, let fraction):
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(pass == 1 ? "Reading" : "Read \(pass)").font(.callout)
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
        case .finished(let track):
            FinishedStatus(track: track, ctdb: ctdb, summary: summary)
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

    var body: some View {
        let verdict = TrackVerdict(track, ctdb: ctdb)
        HStack(spacing: 5) {
            Image(systemName: verdict.icon).foregroundStyle(verdict.color)
            Text(verdict.text).foregroundStyle(verdict.color)
        }
        .help(summary ?? help(for: verdict))
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
            Text(count > 0 ? Format.count(count, "sector") : Format.count(unreadable, "unreadable"))
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

struct RepairedCell: View {
    var track: RipReport.Track

    var body: some View {
        if track.repairedSamples > 0 {
            Text(track.repairedSamples.formatted() + " samples").foregroundStyle(Theme.warning)
                .help("Samples that CTDB's repair data corrected.")
        } else {
            Text("—").foregroundStyle(.secondary)
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
                Text("Accurate · conf \(confidence)").foregroundStyle(Theme.good)
            case .otherPressings:
                Text("Other pressing").foregroundStyle(Theme.good)
                    .help("Matches AccurateRip at other offsets only, so it is free of errors.")
            case .notAccurate:
                Text("Not accurate").foregroundStyle(Theme.bad)
            case .notInDatabase:
                Text("Not in database").foregroundStyle(.secondary)
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
            if let confidence = track.ctdbConfidence, confidence > 0 {
                Text("Verified · \(confidence)").foregroundStyle(Theme.good)
            } else if let ctdb = run.ctdb {
                switch ctdb.status {
                case .verified, .repaired: Text("Verified").foregroundStyle(Theme.good)
                case .partlyRepaired, .notVerified: Text("Not verified").foregroundStyle(Theme.bad)
                case .notInDatabase: Text("Not in database").foregroundStyle(.secondary)
                case .notChecked: Text("Not checked").foregroundStyle(.secondary)
                }
            } else if run.isRunning {
                Text("Pending").foregroundStyle(.secondary)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}
