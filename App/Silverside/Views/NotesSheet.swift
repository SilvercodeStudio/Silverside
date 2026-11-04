import SilversideKit
import SwiftUI

/// The user's notes on an earlier rip: free text, kept in its report and the history, and shown
/// in Rip History's Notes column and on the rip's page.
struct NotesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let rip: RecentRip
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notes on “\(rip.title)”").font(.headline)
            Text("Anything you want to remember about this disc or rip. Rip History searches them.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                .frame(minHeight: 140)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.saveNotes(text, of: rip)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 300)
        .onAppear { text = rip.notes }
    }
}
