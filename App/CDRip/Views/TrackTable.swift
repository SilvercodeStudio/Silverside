import CDRipKit
import SwiftUI

/// The tracks of the disc, with their rip status.
struct TrackTable: View {
    @Bindable var slot: DriveSlot
    @State private var tableSelection: Set<Int> = []

    var body: some View {
        Table(slot.disc?.tracks(from: slot.namesSource) ?? [], selection: $tableSelection) {
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
                    Text(track.title)
                    if let artist = track.artist { Text(artist).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .width(min: 220, ideal: 360)
            TableColumn("Time") { track in
                Text(track.duration).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(52)
            TableColumn("Status") { track in
                StatusCell(state: slot.rip?.trackStates[track.number], summary: slot.rip?.summaries[track.number])
            }
            .width(min: 200, ideal: 280)
            TableColumn("AccurateRip") { track in
                AccurateRipCell(state: slot.rip?.trackStates[track.number])
            }
            .width(min: 110, ideal: 150)
            TableColumn("CTDB") { track in
                CTDBCell(run: slot.rip, number: track.number)
            }
            .width(min: 70, ideal: 110)
        }
        .alternatingRowBackgrounds(.disabled)
    }

    private func binding(for number: Int) -> Binding<Bool> {
        Binding(
            get: { slot.selectedTracks.contains(number) },
            set: { if $0 { slot.selectedTracks.insert(number) } else { slot.selectedTracks.remove(number) } })
    }
}

struct StatusCell: View {
    var state: RipRun.TrackState?
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
            FinishedStatus(track: track, summary: summary)
        }
    }
}

struct FinishedStatus: View {
    var track: RipReport.Track
    var summary: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).foregroundStyle(color)
        }
        .help(summary ?? "")
    }

    private var isRight: Bool {
        track.accurateRip == .accurate || track.accurateRip == .otherPressings || (track.ctdbConfidence ?? 0) > 0
    }

    /// Reads that disagreed, sectors that could not be read, or a repair. Two reads that agree are normal.
    private var hadTrouble: Bool {
        !track.suspectSectors.isEmpty || !(track.unreadableSectors ?? []).isEmpty || track.repairedSamples > 0
    }

    private var icon: String {
        if !track.unresolvedSectors.isEmpty { return "xmark.circle" }
        if hadTrouble { return "exclamationmark.triangle" }
        return "checkmark"
    }

    private var color: Color {
        if !track.unresolvedSectors.isEmpty { return Theme.bad }
        if hadTrouble { return Theme.warning }
        return isRight ? Theme.good : .secondary
    }

    private var text: String {
        var parts = [String]()
        parts.append(isRight ? "Copy OK" : "Copied")
        if track.repairedSamples > 0 { parts.append("\(track.repairedSamples) samples repaired") }
        if !track.unresolvedSectors.isEmpty {
            parts.append("\(Format.count(track.unresolvedSectors.count, "sector")) unresolved")
        } else if !track.suspectSectors.isEmpty {
            parts.append("\(Format.count(track.suspectSectors.count, "sector")) re-read")
        } else if track.fullReads > 1 {
            parts.append("\(track.fullReads) reads")
        }
        if let unreadable = track.unreadableSectors, !unreadable.isEmpty {
            parts.append("\(unreadable.count) unreadable")
        }
        return parts.joined(separator: " · ")
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
