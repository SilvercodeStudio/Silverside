import SilversideKit
import SwiftUI

/// Every rip Silverside knows, from the rips folder and the library: a table to search and sort.
/// A row opens the rip's results. The search, the order, and the selection are the model's, so
/// that Back from a rip finds the table as it was.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    /// The rows found and sorted, worked out again only when the search, the order, or the rips change.
    @State private var rows: [RecentRip] = []

    private func findRows() {
        let needle = model.historySearch.trimmingCharacters(in: .whitespaces)
        let found =
            needle.isEmpty
            ? model.allRips
            : model.allRips.filter {
                [$0.title, $0.artist, $0.report.drive.product, $0.medium].contains {
                    PlainPunctuation.text($0, contains: needle)
                }
            }
        rows = found.sorted(using: model.historyOrder)
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Rip History").font(.title2.weight(.semibold))
                Text(summary).foregroundStyle(.secondary)
                Spacer()
                if !model.missingRips.isEmpty {
                    Button("Look for Moved Rips…") { model.locateMissingRips() }
                        .help(
                            "Choose a folder, such as a NAS, where moved albums or rips are. Silverside keeps their new places."
                        )
                }
            }
            .padding(16)
            Divider()
            Table(rows, selection: $model.historySelection, sortOrder: $model.historyOrder) {
                TableColumn("Date", value: \.date) { rip in DateCell(date: rip.date) }.width(min: 150, ideal: 170)
                TableColumn("Album", value: \.title).width(min: 200, ideal: 320)
                TableColumn("Artist", value: \.artist).width(min: 120, ideal: 200)
                TableColumn("Result", value: \.verifiedCount) { rip in ResultCell(rip: rip) }.width(
                    min: 120, ideal: 160)
                TableColumn("Medium", value: \.medium).width(min: 80, ideal: 130)
                TableColumn("Drive", value: \.driveName).width(min: 150, ideal: 220)
                TableColumn("Where", value: \.location).width(min: 80, ideal: 100)
            }
            .alternatingRowBackgrounds(.disabled)
            .contextMenu(forSelectionType: URL.self) { files in
                if let file = files.first, let rip = model.allRips.first(where: { $0.file == file }) {
                    Button("Show Results") { model.selection = .rip(rip.file) }
                    if rip.isMissing {
                        Button("Look for Moved Rips…") { model.locateMissingRips() }
                        Button("Remove from History") { model.forget(rip) }
                    } else {
                        Button("Show in Finder") { model.revealInFinder(rip.folder) }
                        Button("Change Release…") { model.changingRelease = rip }
                            .disabled(!model.canChangeRelease(rip))
                        Divider()
                        Button("Move to Trash…") { model.moveToTrash(rip) }.disabled(!model.canMoveToTrash(rip))
                    }
                }
            } primaryAction: { files in
                if let file = files.first { model.selection = .rip(file) }
            }
        }
        .navigationTitle("Rip History")
        .tableSearch($model.historySearch, prompt: "Album, artist, medium, or drive")
        .onAppear(perform: findRows)
        .onChange(of: model.historySearch, findRows)
        .onChange(of: model.historyOrder, findRows)
        .onChange(of: model.listsVersion, findRows)
    }

    private var summary: String {
        let all = model.allRips
        let unverified = all.filter { !$0.isVerified }.count
        var text = Format.count(all.count, "rip")
        if unverified > 0 { text += ", \(unverified) not verified" }
        if !model.missingRips.isEmpty { text += ", \(model.missingRips.count) moved or deleted" }
        if !model.historySearch.isEmpty { text += " · \(Format.count(rows.count, "match", plural: "matches"))" }
        return text
    }

}

struct DateCell: View {
    var date: Date

    var body: some View {
        Text(date.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
    }
}

private struct ResultCell: View {
    var rip: RecentRip

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: rip.isVerified ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(rip.isVerified ? Theme.good : Theme.warning)
        }
    }

    private var text: String {
        let total = rip.report.tracks.count
        if rip.isVerified { return "Verified, \(Format.count(total, "track"))" }
        return "\(rip.verifiedCount) of \(total) verified"
    }
}
