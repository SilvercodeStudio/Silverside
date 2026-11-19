import SilversideKit
import SwiftUI

/// Searches MusicBrainz for a disc's release, by its names, its barcode, or its catalog number,
/// when the disc's ID found none (a pressing whose disc ID MusicBrainz does not have) or the
/// wrong one. Each release shows its cover and what tells editions apart, and whether one of its
/// discs has as many tracks as this one; the release chosen is looked up by its ID, and is
/// usable only when one of its discs fits this one, by its track count and lengths.
struct ReleaseSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let toc: TOC
    /// What to search for first: the disc's names, such as "Dave Brubeck Seven Classic LPs".
    let initialQuery: String
    /// What the chosen release is used for, in the button: "Use This Release", "Change Release".
    let actionTitle: String
    /// For an earlier rip: offers Keep My Track Titles, and gives `choose` the answer.
    var offersKeepingTitles = false
    var choose: (MusicBrainzRelease, _ keepsTitles: Bool) -> Void
    @AppStorage("changeReleaseKeepsTitles") private var keepsTitles = false

    @State private var query = ""
    /// The search's pages so far, each as MusicBrainz ordered it; nil before a search.
    @State private var pages: [[MusicBrainzSearchResult]]?
    /// The text that `pages` are for, which More Results goes on with, also after the field changed.
    @State private var searched = ""
    /// Where the next page starts; nil when MusicBrainz has no more, or the search has its most.
    @State private var nextOffset: Int?
    @State private var loadingMore = false
    @State private var moreFailure: String?
    /// Counts the searches, so that a page asked for in an earlier one is dropped.
    @State private var generation = 0
    @State private var searching = false
    @State private var failure: String?
    @State private var selected: String?
    @State private var thumbnails = [String: Data]()
    /// The selected release, looked up by its ID, with its tracks; nil while it is looked up.
    @State private var detailed: MusicBrainzRelease?
    @State private var detailFailure: String?

    private var trackCount: Int { toc.sessionAudioTracks.count }

    private var results: [MusicBrainzSearchResult]? { pages?.flatMap { $0 } }

    /// In each page, the results whose discs could be this one (as many tracks) first, in
    /// MusicBrainz's order. A later page goes after the ones before it, so its results appear
    /// where More Results was, and nothing above moves.
    private var ordered: [MusicBrainzSearchResult] {
        (pages ?? []).flatMap(orderedPage)
    }

    private func orderedPage(_ page: [MusicBrainzSearchResult]) -> [MusicBrainzSearchResult] {
        page.filter { fits($0) } + page.filter { !fits($0) }
    }

    private func fits(_ result: MusicBrainzSearchResult) -> Bool {
        !result.positions(withTrackCount: trackCount).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search MusicBrainz").font(.headline)
            Text(
                "Find this disc's release by its names, its barcode, its catalog number, or a link to it in MusicBrainz. A release with a disc of \(Format.count(trackCount, "track")), as this one has, comes first; the one you choose must have a disc whose track lengths fit. Then Add Disc ID… sends this disc's ID to MusicBrainz, so the next lookup finds it by itself."
            )
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Artist, album, barcode, catalog number, or MusicBrainz link", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
            HStack {
                if let selected {
                    Link(
                        "Open in MusicBrainz", destination: URL(string: "https://musicbrainz.org/release/\(selected)")!
                    )
                    .font(.callout)
                }
                Spacer()
                if offersKeepingTitles {
                    Toggle("Keep my track titles", isOn: $keepsTitles)
                        .help(
                            "Each track keeps the title it has now. The album's names, the date, the composers, and the MusicBrainz IDs are the new release's."
                        )
                }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(actionTitle) { use() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(detailed?.fit(for: toc) == nil)
            }
        }
        .padding(20)
        .frame(width: 820, height: 620)
        .task {
            query = initialQuery
            await search()
        }
        .task(id: selected) { await lookUpSelected() }
    }

    @ViewBuilder private var content: some View {
        if searching {
            ProgressView("Searching MusicBrainz…")
        } else if let failure {
            Text(failure).foregroundStyle(Theme.warning)
        } else if let results, results.isEmpty {
            Text(
                MusicBrainzClient.link(in: query) != nil
                    ? "MusicBrainz has no release there. Paste the link to a release or a release group."
                    : "MusicBrainz found no release. Try fewer words, or the barcode on the back of the case."
            )
            .foregroundStyle(.secondary)
        } else if results != nil {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(ordered) { result in
                        // A button, so that the keyboard and VoiceOver can choose a release too.
                        Button {
                            selected = result.id
                        } label: {
                            card(result).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected == result.id ? .isSelected : [])
                    }
                }
                .padding(4)
                moreResults
            }
            .task(id: results?.map(\.id)) { await loadThumbnails() }
        }
    }

    /// More Results, under the results while MusicBrainz has more: the next page, one request.
    @ViewBuilder private var moreResults: some View {
        if loadingMore || moreFailure != nil || nextOffset != nil {
            VStack(spacing: 6) {
                if let moreFailure {
                    Text(moreFailure).font(.callout).foregroundStyle(Theme.warning)
                }
                if loadingMore {
                    ProgressView().controlSize(.small)
                } else if nextOffset != nil {
                    Button("More Results") { Task { await loadMore() } }
                        .help(
                            "Shows the next \(MusicBrainzSearchPage.size) releases that MusicBrainz found, up to \(MusicBrainzSearchPage.mostResults) in all. More words, the barcode, or a link to the release narrow the search."
                        )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private func card(_ result: MusicBrainzSearchResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let data = thumbnails[result.id], let picture = NSImage(data: data) {
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Color.secondary.opacity(0.12).overlay {
                        Image(systemName: "opticaldisc").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                Text(result.title).font(.callout.weight(.semibold)).lineLimit(2)
                Text(result.artist).font(.caption).lineLimit(1)
                Text(Self.details(of: result)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .help(Self.details(of: result))
                Spacer(minLength: 0)
                let positions = result.positions(withTrackCount: trackCount)
                if positions.isEmpty {
                    Text("No disc of \(Format.count(trackCount, "track"))").font(.caption).foregroundStyle(.secondary)
                } else {
                    Chip(
                        text: result.media.count == 1
                            ? Format.count(trackCount, "track")
                            : positions.count == 1
                                ? "Disc \(positions[0]) may fit"
                                : "Discs \(positions.map(String.init).joined(separator: ", ")) may fit",
                        tone: .good,
                        help:
                            "A disc of \(Format.count(trackCount, "track")), as this one has. Select the release to compare the track lengths."
                    )
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 132, maxHeight: 132, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected == result.id ? Color.accentColor : .clear, lineWidth: 3)
        }
        .contentShape(Rectangle())
        .help("MusicBrainz's score for the match: \(result.score)")
    }

    /// "2019 · GB · 4×CD · Enlightenment EN4CD9161 · barcode 823564030142".
    static func details(of result: MusicBrainzSearchResult) -> String {
        var parts = [result.date, result.country].compactMap { $0 }
        if !result.formats.isEmpty { parts.append(result.formats) }
        parts += result.labels
        if let barcode = result.barcode { parts.append("barcode \(barcode)") }
        if let status = result.status, status != "Official" { parts.append(status.lowercased()) }
        if let disambiguation = result.disambiguation { parts.append(disambiguation) }
        return parts.joined(separator: " · ")
    }

    /// Whether the selected release has this disc: the disc that fits by its track lengths.
    @ViewBuilder private var footer: some View {
        if selected != nil {
            Group {
                if let detailFailure {
                    Text(detailFailure).foregroundStyle(Theme.warning)
                } else if let detailed {
                    if let fit = detailed.fit(for: toc) {
                        let disc =
                            detailed.media.count > 1 ? "Disc \(fit.medium.position) of \(detailed.media.count)" : "It"
                        switch fit.kind {
                        case .discID:
                            Label("\(disc) has this disc's ID.", systemImage: "checkmark.circle")
                                .foregroundStyle(Theme.good)
                        case .lengths:
                            Label("\(disc) fits this disc's track lengths.", systemImage: "checkmark.circle")
                                .foregroundStyle(Theme.good)
                        case .trackCountOnly:
                            Label(
                                "\(disc) has \(Format.count(trackCount, "track")), but MusicBrainz has no lengths to compare. Check the titles in MusicBrainz first.",
                                systemImage: "questionmark.circle"
                            )
                            .foregroundStyle(Theme.warning)
                        }
                    } else {
                        Label(
                            "No disc of this release fits this one: the number of tracks or their lengths differ, so it may be another recording.",
                            systemImage: "xmark.circle"
                        )
                        .foregroundStyle(Theme.warning)
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Looking up the release…").foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        generation += 1
        searching = true
        failure = nil
        moreFailure = nil
        selected = nil
        nextOffset = nil
        loadingMore = false
        defer { searching = false }
        do {
            let page = try await MusicBrainzClient().searchReleasePage(text)
            let found = page.results
            pages = [found]
            searched = text
            nextOffset = page.nextOffset
            // One release, such as a link's, is selected even when no disc of it has as many
            // tracks: the footer then says why it does not fit.
            selected = ordered.first(where: fits)?.id ?? (found.count == 1 ? found[0].id : nil)
        } catch {
            pages = nil
            failure = "The search failed: \(error)"
        }
    }

    /// The search's next page, after the ones shown; a release already shown is left out.
    private func loadMore() async {
        guard let offset = nextOffset, !loadingMore else { return }
        let search = generation
        loadingMore = true
        moreFailure = nil
        defer { if search == generation { loadingMore = false } }
        do {
            let page = try await MusicBrainzClient().searchReleasePage(searched, offset: offset)
            guard search == generation else { return }
            let shown = Set(results?.map(\.id) ?? [])
            pages = (pages ?? []) + [page.results.filter { !shown.contains($0.id) }]
            nextOffset = page.nextOffset
        } catch {
            guard search == generation else { return }
            moreFailure = "MusicBrainz did not give more results: \(error)"
        }
    }

    /// The selected release, by its ID: one request, from the cache when it was looked up before.
    private func lookUpSelected() async {
        detailed = nil
        detailFailure = nil
        guard let id = selected else { return }
        do {
            let release = try await MusicBrainzClient().release(id: id)
            guard selected == id else { return }
            detailed = release
            if release == nil { detailFailure = "MusicBrainz no longer has this release." }
        } catch {
            guard selected == id else { return }
            detailFailure = "The release could not be looked up: \(error)"
        }
    }

    /// The covers, one after another, as the Cover Art Archive asks: the first 16 of each page,
    /// the releases that may be this disc's first.
    private func loadThumbnails() async {
        for result in (pages ?? []).flatMap({ orderedPage($0).prefix(16) }) where thumbnails[result.id] == nil {
            guard !Task.isCancelled else { return }
            if let data = try? await CoverArtClient().frontThumbnail(releaseID: result.id) {
                thumbnails[result.id] = data
            }
        }
    }

    private func use() {
        guard let detailed, detailed.fit(for: toc) != nil else { return }
        choose(detailed, offersKeepingTitles && keepsTitles)
        dismiss()
    }
}

/// The MusicBrainz search for the disc in a drive, whose release it becomes, or for an earlier
/// rip, whose release it changes (`AppModel.releaseSearchTarget`).
struct ReleaseSearchTargetSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: AppModel.DiscTarget

    var body: some View {
        switch target {
        case .drive(let slot):
            if let disc = slot.disc {
                ReleaseSearchSheet(toc: disc.toc, initialQuery: disc.searchText, actionTitle: "Use This Release") {
                    found, _ in slot.useFound(found)
                }
                // The sheet is for this disc only: another in the drive, or none, closes it.
                .onChange(of: slot.disc?.toc.musicBrainzDiscID) { dismiss() }
            } else {
                Color.clear.frame(width: 1, height: 1).onAppear { dismiss() }
            }
        case .rip(let rip):
            if let toc = try? TOC(ctdbTOCString: rip.report.toc) {
                Self.forRip(rip, toc: toc) { model.changeRelease(of: rip, to: $0, keepingTitles: $1) }
            }
        }
    }

    /// The search for an earlier rip, from its names now.
    static func forRip(
        _ rip: RecentRip, toc: TOC, choose: @escaping (MusicBrainzRelease, Bool) -> Void
    ) -> ReleaseSearchSheet {
        let shown = rip.report.release.map {
            MetadataEdits.current(forReportAt: rip.file, release: $0).applied(to: $0, toc: toc)
        }
        let title = shown.map { CDTextHints.disc(inAlbumTitle: $0.title)?.title ?? $0.title } ?? ""
        return ReleaseSearchSheet(
            toc: toc, initialQuery: [shown?.artist ?? "", title].filter { !$0.isEmpty }.joined(separator: " "),
            actionTitle: "Change Release", offersKeepingTitles: true, choose: choose)
    }
}
