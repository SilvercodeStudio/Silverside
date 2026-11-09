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
    @State private var results: [MusicBrainzSearchResult]?
    @State private var searching = false
    @State private var failure: String?
    @State private var selected: String?
    @State private var thumbnails = [String: Data]()
    /// The selected release, looked up by its ID, with its tracks; nil while it is looked up.
    @State private var detailed: MusicBrainzRelease?
    @State private var detailFailure: String?

    private var trackCount: Int { toc.audioTracks.count }

    /// The results whose discs could be this one (as many tracks) first, in MusicBrainz's order.
    private var ordered: [MusicBrainzSearchResult] {
        let all = results ?? []
        return all.filter { fits($0) } + all.filter { !fits($0) }
    }

    private func fits(_ result: MusicBrainzSearchResult) -> Bool {
        !result.positions(withTrackCount: trackCount).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search MusicBrainz").font(.headline)
            Text(
                "Find this disc's release by its names, its barcode, or its catalog number. A release with a disc of \(Format.count(trackCount, "track")), as this one has, comes first; the one you choose must have a disc whose track lengths fit. Then Add Disc ID… sends this disc's ID to MusicBrainz, so the next lookup finds it by itself."
            )
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Artist, album, barcode, or catalog number", text: $query)
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
            Text("MusicBrainz found no release. Try fewer words, or the barcode on the back of the case.")
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
            }
            .task(id: results?.map(\.id)) { await loadThumbnails() }
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
        searching = true
        failure = nil
        selected = nil
        defer { searching = false }
        do {
            results = try await MusicBrainzClient().searchReleases(text)
            selected = ordered.first(where: fits)?.id
        } catch {
            results = nil
            failure = "The search failed: \(error)"
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

    /// The covers, one after another, as the Cover Art Archive asks; the releases that may be
    /// this disc's first.
    private func loadThumbnails() async {
        for result in ordered.prefix(16) where thumbnails[result.id] == nil {
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
