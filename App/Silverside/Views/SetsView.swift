import SilversideKit
import SwiftUI

/// Every multi-disc set among the earlier rips: a table to search and sort. A row opens the
/// set's page, whose discs open their results as the history's rows do. The search, the
/// order, and the selection are the model's, so that Back from a set finds the table as it was.
struct SetsView: View {
    @Environment(AppModel.self) private var model
    /// The rows found and sorted, worked out again only when the search, the order, or the sets change.
    @State private var rows: [RipSet] = []

    private func findRows() {
        let needle = model.setsSearch.trimmingCharacters(in: .whitespaces)
        let found =
            needle.isEmpty
            ? model.sets
            : model.sets.filter { [$0.title, $0.artist].contains { PlainPunctuation.text($0, contains: needle) } }
        rows = found.sorted(using: model.setsOrder)
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sets").font(.title2.weight(.semibold))
                Text(summary).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(16)
            Divider()
            Table(rows, selection: $model.setsSelection, sortOrder: $model.setsOrder) {
                TableColumn("Last Ripped", value: \.lastRipped) { set in DateCell(date: set.lastRipped) }
                    .width(min: 150, ideal: 170)
                TableColumn("Album", value: \.title).width(min: 200, ideal: 320)
                TableColumn("Artist", value: \.artist).width(min: 120, ideal: 200)
                TableColumn("Discs", value: \.discCount) { set in Text(set.discsText) }.width(min: 80, ideal: 110)
                TableColumn("State", value: \.discsToDo) { set in SetStateCell(set: set) }.width(min: 140, ideal: 260)
            }
            .alternatingRowBackgrounds(.disabled)
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first {
                    Button("Show Set") { model.selection = .set(id) }
                }
            } primaryAction: { ids in
                if let id = ids.first { model.selection = .set(id) }
            }
        }
        .navigationTitle("Sets")
        .tableSearch($model.setsSearch, prompt: "Album or artist")
        .onAppear(perform: findRows)
        .onChange(of: model.setsSearch, findRows)
        .onChange(of: model.setsOrder, findRows)
        .onChange(of: model.listsVersion, findRows)
    }

    private var summary: String {
        let sets = model.sets
        let done = sets.filter(\.isComplete).count
        var text = Format.count(sets.count, "set") + ", \(done) done"
        if !model.setsSearch.isEmpty { text += " · \(Format.count(rows.count, "match", plural: "matches"))" }
        return text
    }
}

extension RipSet {
    /// The discs still to rip, verify, or encode, for sorting by what is left.
    fileprivate var discsToDo: Int { missing.count + unfinished.count }
}

private struct SetStateCell: View {
    var set: RipSet

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: set.isComplete ? "checkmark.circle" : "circle.dashed")
                .foregroundStyle(set.isComplete ? Theme.good : .secondary)
        }
        .help(set.summary)
    }

    /// "Done", "2 to rip", "1 to rip, 1 to finish".
    private var text: String {
        var parts = [String]()
        if !set.missing.isEmpty { parts.append("\(set.missing.count) to rip") }
        if !set.unfinished.isEmpty { parts.append("\(set.unfinished.count) to finish") }
        return parts.isEmpty ? "Done" : parts.joined(separator: ", ")
    }
}
