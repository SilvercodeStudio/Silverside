import CDRipKit
import SwiftUI

/// Every rip Silverside knows, from the rips folder and the library: a table to search and sort.
/// A row opens the rip's results.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selected: URL?
    @State private var sortOrder = [KeyPathComparator(\RecentRip.date, order: .reverse)]

    private var rows: [RecentRip] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let found =
            needle.isEmpty
            ? model.recentRips
            : model.recentRips.filter {
                $0.title.lowercased().contains(needle) || $0.artist.lowercased().contains(needle)
                    || $0.report.drive.product.lowercased().contains(needle)
            }
        return found.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Rip History").font(.title2.weight(.semibold))
                Text(summary).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(16)
            Divider()
            Table(rows, selection: $selected, sortOrder: $sortOrder) {
                TableColumn("Date", value: \.date) { rip in DateCell(date: rip.date) }.width(min: 150, ideal: 170)
                TableColumn("Album", value: \.title).width(min: 200, ideal: 320)
                TableColumn("Artist", value: \.artist).width(min: 120, ideal: 200)
                TableColumn("Result", value: \.verifiedCount) { rip in ResultCell(rip: rip) }.width(
                    min: 120, ideal: 160)
                TableColumn("Drive", value: \.driveName).width(min: 150, ideal: 220)
                TableColumn("Where", value: \.location).width(min: 80, ideal: 100)
            }
            .alternatingRowBackgrounds(.disabled)
            .contextMenu(forSelectionType: URL.self) { files in
                if let file = files.first, let rip = model.recentRips.first(where: { $0.file == file }) {
                    Button("Show Results") { model.selection = .rip(rip.file) }
                    Button("Show in Finder") { model.revealInFinder(rip.folder) }
                }
            } primaryAction: { files in
                if let file = files.first { model.selection = .rip(file) }
            }
        }
        .navigationTitle("Rip History")
        .searchable(text: $search, placement: .toolbar, prompt: "Album, artist, or drive")
    }

    private var summary: String {
        let all = model.recentRips
        let unverified = all.filter { !$0.isVerified }.count
        var text = Format.count(all.count, "rip")
        if unverified > 0 { text += ", \(unverified) not verified" }
        if !search.isEmpty { text += " · \(Format.count(rows.count, "match"))" }
        return text
    }

}

private struct DateCell: View {
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
