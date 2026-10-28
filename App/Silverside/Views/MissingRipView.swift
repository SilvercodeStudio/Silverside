import SilversideKit
import SwiftUI

/// A rip that only the history has: its files were moved or deleted. Its report and graph
/// still show; Look for It… finds it in a folder the user chooses, such as a NAS.
struct MissingRipView: View {
    @Environment(AppModel.self) private var model
    var rip: RecentRip

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(rip.title).font(.title2.weight(.semibold))
                Text(rip.subtitle).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "questionmark.folder").font(.title2).foregroundStyle(Theme.warning)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Moved or deleted").font(.headline)
                        Text(
                            "The rip's files are no longer at \((rip.folder.path as NSString).abbreviatingWithTildeInPath). "
                                + "Its report is kept in the history. If you moved the album, Silverside can look for it."
                        )
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Look for It…") { model.locateMissingRips() }
                    Button("Remove from History") { model.forget(rip) }
                }
                .padding(12)
                .background(Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(16)
            DiscGraph(tracks: DiscGraph.tracks(of: rip.report)).padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            HelpWebView(html: MarkdownHTML.page(MarkdownHTML.render(rip.report.markdown), compact: true))
        }
    }
}
