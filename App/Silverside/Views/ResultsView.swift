import SilversideKit
import SwiftUI

/// An earlier rip: the headline, each track's result, and the report as text.
struct ResultsView: View {
    @Environment(AppModel.self) private var model
    var folder: URL
    var report: RipReport
    /// False for a report kept in the library after the rip's WAV files were deleted.
    var hasAudio = true
    @State private var reportShown = true

    private var toc: TOC? { try? TOC(ctdbTOCString: report.toc) }

    private var titles: [Int: String] {
        guard let toc, let release = report.release, let medium = release.medium(for: toc) else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: zip(toc.audioTracks, medium.tracks).map { ($0.number, $1.title) })
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(16)
                DiscGraph(tracks: DiscGraph.tracks(of: report))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                Divider()
                table
            }
            .frame(minWidth: 640)
            .layoutPriority(1)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Rip Report").font(.headline)
                    Spacer()
                    Button("Copy as Markdown") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.markdown, forType: .string)
                    }
                }
                .padding(12)
                Divider()
                HelpWebView(
                    html: MarkdownHTML.page(MarkdownHTML.render(Self.withoutTrackTable(report.markdown)), compact: true)
                )
            }
            .frame(minWidth: 300, idealWidth: 380, maxWidth: 560)
            .background(Color.secondary.opacity(0.04))
            .opacity(reportShown ? 1 : 0)
            .frame(width: reportShown ? nil : 0)
        }
        .navigationTitle(report.release.map { "\($0.title)" } ?? folder.lastPathComponent)
        .navigationSubtitle(
            [report.release?.artist, report.drive.vendor + " " + report.drive.product].compactMap { $0 }.joined(
                separator: " · ")
        )
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
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
            }
        }
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
            Image(systemName: report.isVerified ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(report.isVerified ? Theme.good : Theme.warning)
            VStack(alignment: .leading, spacing: 6) {
                Text(RipRun.headline(for: report)).font(.title2.weight(.semibold))
                Text(
                    "Ripped \(report.date.formatted(date: .abbreviated, time: .shortened)) on \(report.drive.vendor) \(report.drive.product), read offset \(report.drive.readOffset.signedDescription), \(report.secure ? "secure" : "one read per track")."
                )
                .foregroundStyle(.secondary)
                ChipRow(chips: ResultChips.chips(for: report))
                if let advice = report.advice {
                    Text(advice).font(.callout).foregroundStyle(.secondary)
                }
                if let set = model.set(for: report.release) {
                    Text(setText(set)).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "Disc 2 of 3 · Discs 1 and 2 of 3 ripped; disc 3 still to do".
    private func setText(_ set: RipSet) -> String {
        let position = report.discPosition.map { "Disc \($0) of \(set.discCount) · " } ?? ""
        return position + set.summary
    }

    private var table: some View {
        Table(report.tracks) {
            TableColumn("#") { track in Text(String(track.number)).foregroundStyle(.secondary) }.width(28)
            TableColumn("Title") { track in Text(titles[track.number] ?? track.file) }.width(min: 160, ideal: 260)
            TableColumn("Time") { track in Text(Format.duration(sectors: track.sectors)).foregroundStyle(.secondary) }
                .width(52)
            TableColumn("Status") { track in FinishedStatus(track: track, ctdb: report.ctdb) }.width(
                min: 110, ideal: 130)
            TableColumn("Re-reads") { track in RereadsCell(track: track, ctdb: report.ctdb) }.width(min: 80, ideal: 100)
            TableColumn("Repaired") { track in RepairedCell(track: track) }.width(min: 90, ideal: 110)
            TableColumn("AccurateRip") { track in AccurateRipCell(state: .finished(track)) }.width(min: 100, ideal: 140)
            TableColumn("CTDB") { track in
                if let confidence = track.ctdbConfidence, confidence > 0 {
                    Text("Verified · \(confidence)").foregroundStyle(Theme.good)
                } else {
                    switch report.ctdb.status {
                    case .verified, .repaired: Text("Verified").foregroundStyle(Theme.good)
                    case .partlyRepaired, .notVerified: Text("Not verified").foregroundStyle(Theme.bad)
                    case .notInDatabase: Text("Not in database").foregroundStyle(.secondary)
                    case .notChecked: Text("Not checked").foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 80, ideal: 110)
        }
        .alternatingRowBackgrounds(.disabled)
    }
}
