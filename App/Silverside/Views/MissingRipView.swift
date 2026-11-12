import SilversideKit
import SwiftUI

/// A rip that only the history has: its files were moved or deleted, another rip of the disc
/// took its place (replaced), or its place cannot be reached now (offline: a NAS not mounted).
/// Its report and graph still show; Look for It… finds a moved rip in a folder the user
/// chooses, such as a NAS.
struct MissingRipView: View {
    @Environment(AppModel.self) private var model
    var rip: RecentRip

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(rip.title).font(.title2.weight(.semibold))
                Text(rip.subtitle).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol).font(.title2).foregroundStyle(tint).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(heading).font(.headline)
                        Text(explanation)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    if let later {
                        Button("Show That Rip") { model.selection = .rip(later.id) }
                        Button("Remove from History") { model.forget(rip) }
                    } else if !rip.isOffline {
                        Button("Look for It…") { model.locateMissingRips() }
                        Button("Remove from History") { model.forget(rip) }
                    }
                }
                .padding(12)
                .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(16)
            DiscGraph(tracks: DiscGraph.tracks(of: rip.report)).padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            HelpWebView(html: MarkdownHTML.page(MarkdownHTML.render(rip.report.markdown), compact: true))
        }
    }

    /// The rip of the disc that is at this rip's place now, for a replaced rip.
    private var later: RecentRip? {
        guard rip.isReplaced, let other = model.rip(at: rip.file), other.id != rip.id else { return nil }
        return other
    }

    private var heading: String { rip.isOffline ? "Offline" : rip.isReplaced ? "Replaced" : "Moved or deleted" }

    private var symbol: String {
        rip.isOffline
            ? "externaldrive.badge.xmark" : rip.isReplaced ? "arrow.triangle.2.circlepath" : "questionmark.folder"
    }

    /// Offline and replaced are not problems: neither asks for anything.
    private var tint: Color { rip.isOffline || rip.isReplaced ? .secondary : Theme.warning }

    private var explanation: String {
        let folder = (rip.folder.path as NSString).abbreviatingWithTildeInPath
        if let later {
            return "The disc was ripped again into \(folder), and the rip of "
                + "\(later.date.formatted(date: .abbreviated, time: .shortened)) took this one's place. "
                + "This rip's report is kept in the history."
        }
        return rip.isOffline
            ? "Silverside cannot reach \(folder) now: its disk or network share is not connected. "
                + "When it is, Silverside looks again, and the rip shows as before."
            : "The rip's files are no longer at \(folder). "
                + "Its report is kept in the history. If you moved the album, Silverside can look for it."
    }
}
