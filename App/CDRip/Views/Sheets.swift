import CDRipKit
import SwiftUI

/// Picks one of the MusicBrainz releases that have the disc.
struct ReleasePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var disc: DiscInfo
    var choose: (MusicBrainzRelease) -> Void
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which release is this disc from?").font(.headline)
            Text(
                disc.isFuzzy
                    ? "MusicBrainz does not know this disc ID. These releases have nearly the same TOC."
                    : "Several releases in MusicBrainz have this disc. The choice is kept for the other discs of the release."
            )
            .foregroundStyle(.secondary)
            List(disc.releases, id: \.id, selection: $selected) { release in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(release.artist) – \(release.title)").font(.body.weight(.medium))
                    Text(details(of: release)).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(release.id)
            }
            .frame(minHeight: 220)
            if disc.isFuzzy {
                Link(
                    "Add this disc ID to the right release in MusicBrainz",
                    destination: MusicBrainzRelease.submissionURL(for: disc.toc)
                )
                .font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use This Release") {
                    if let release = disc.releases.first(where: { $0.id == selected }) { choose(release) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 640, height: 440)
        .onAppear { selected = disc.release?.id ?? disc.releases.first?.id }
    }

    private func details(of release: MusicBrainzRelease) -> String {
        var parts = [String]()
        if let date = release.date { parts.append(date) }
        if let country = release.country { parts.append(country) }
        if release.media.count > 1 {
            if let medium = release.medium(for: disc.toc) {
                parts.append("disc \(medium.position) of \(release.media.count)")
            } else {
                parts.append("\(release.media.count) discs")
            }
        }
        if let barcode = release.barcode, !barcode.isEmpty { parts.append("barcode \(barcode)") }
        let labels = release.labels.compactMap { label in
            [label.name, label.catalogNumber].compactMap { $0 }.joined(separator: " ")
        }.filter { !$0.isEmpty }
        parts.append(contentsOf: labels)
        if let status = release.status, status != "Official" { parts.append(status.lowercased()) }
        if let disambiguation = release.disambiguation, !disambiguation.isEmpty { parts.append(disambiguation) }
        return parts.joined(separator: " · ")
    }
}

/// The rip's log, as `silverside rip` prints it.
struct RipLogView: View {
    @Environment(\.dismiss) private var dismiss
    var run: RipRun?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Rip Log").font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            LogText(lines: run?.log ?? ["No rip yet."])
        }
        .padding(16)
        .frame(width: 720, height: 480)
    }

    private var text: String {
        guard let run else { return "No rip yet." }
        return run.log.joined(separator: "\n")
    }
}

/// Lines of a log, in a box that follows the newest line.
struct LogText: View {
    var lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(Theme.monoSmall)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .id("end")
            }
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: lines.count) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

/// A repair of an earlier rip: what it does, and what it found.
struct RepairSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var run: RepairRun

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if run.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(isGood ? Theme.good : Theme.warning)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Repair · \(run.rip.title)").font(.headline)
                    Text(run.headline).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let folder = run.writtenFolder {
                    Button("Show in Finder") { model.revealInFinder(folder) }
                }
                if run.isRunning {
                    Button("Stop") { run.stop() }.help("Stop after the read under way. Nothing is written.")
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            LogText(lines: run.log)
        }
        .padding(16)
        .frame(width: 720, height: 480)
    }

    private var isGood: Bool {
        switch run.outcome {
        case .verified, .repaired: run.phase == .finished
        default: false
        }
    }
}

/// A drive test or a cache measurement from Settings › Drives: the checks and their results.
struct DriveTestSheet: View {
    @Environment(\.dismiss) private var dismiss
    var run: DriveTestRun

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if run.isRunning { ProgressView().controlSize(.small) }
                Text("\(run.title) · \(run.slot.name)").font(.headline)
                Spacer()
                if run.report != nil {
                    Button("Save Report...") { run.saveReport() }
                        .help("Save the checks and the drive's registry entries as JSON, for a bug report")
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).disabled(run.isRunning)
            }
            if let report = run.report {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(report.checks, id: \.name) { check in
                        GridRow {
                            Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(check.passed ? Theme.good : Theme.bad)
                            Text(check.name)
                            Text(check.result).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                            Text("\(check.milliseconds) ms").foregroundStyle(.secondary).monospacedDigit()
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            LogText(lines: run.log)
        }
        .padding(16)
        .frame(width: 680, height: run.report == nil ? 320 : 540)
    }
}
