import SwiftUI

extension View {
    /// A search field in the toolbar for a long table. What is typed reaches `applied` a moment
    /// after the typing stops, so that the table is not searched and drawn again at each key,
    /// and Find (⌘F, `AppModel.find`) puts the insertion point in it.
    func tableSearch(_ applied: Binding<String>, prompt: String) -> some View {
        modifier(TableSearch(applied: applied, prompt: prompt))
    }
}

private struct TableSearch: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var applied: String
    var prompt: String
    /// The text as typed, until it is applied.
    @State private var typed: String?
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .searchable(
                text: Binding(get: { typed ?? applied }, set: { typed = $0 }), placement: .toolbar,
                prompt: prompt
            )
            .searchFocused($isFocused)
            .task(id: typed) {
                guard let typed, typed != applied else { return }
                // A cleared field shows every row at once.
                if !typed.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
                guard !Task.isCancelled else { return }
                applied = typed
            }
            .onAppear(perform: focusIfAsked)
            .onChange(of: model.wantsSearchField) { focusIfAsked() }
    }

    private func focusIfAsked() {
        guard model.wantsSearchField else { return }
        model.wantsSearchField = false
        // The field is in the toolbar, which a view that just appeared has not filled yet.
        DispatchQueue.main.async { isFocused = true }
    }
}
