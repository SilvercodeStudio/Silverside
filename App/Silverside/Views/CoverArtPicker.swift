import SilversideKit
import SwiftUI

/// The release's images in the Cover Art Archive, to choose the cover from: the archive's
/// main front is the one Silverside takes by itself, but a release can have better ones,
/// such as the art of a digital release or each disc's sleeve in a box set. Other releases
/// of the album can be shown too, for a release with no images of its own, or worse ones.
struct CoverArtPickerSheet: View {
    enum Choice {
        /// One cover for every disc: the image, or nil for the archive's main front.
        case image(CoverImage?)
        /// Each disc of the set takes its own sleeve (see `CoverArtImage.sleeve`).
        case discSleeves
        /// Another release's images, its main front first, become the release's artwork
        /// (`ReleaseCoverStore.useArtwork`).
        case release(String, front: CoverImage)
    }

    @Environment(\.dismiss) private var dismiss
    let release: MusicBrainzRelease
    /// The disc's position in the release, to mark the sleeves made for it. Nil for a whole set.
    var disc: Int?
    /// Other releases of the album to show the images of: the disc lookup's.
    var others: [MusicBrainzRelease] = []
    /// Starts with another release's images, not this one's.
    var startsWithOthers = false
    /// Starts with this release's images (the one whose images the cover shows).
    var startsWith: String?
    var choose: (Choice) -> Void

    /// The release whose images show.
    @State private var source: String?
    /// The release that the archive takes for the album's release group, if not among the others.
    @State private var groupChoice: String?
    @State private var images: [CoverArtImage]?
    @State private var thumbnails = [String: Data]()
    /// The images whose thumbnail could not be downloaded.
    @State private var missingThumbnails = Set<String>()
    @State private var failure: String?
    @State private var selected: String?
    @State private var downloading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cover Art Archive").font(.headline)
            Text(introduction)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if sources.count > 1 {
                Picker("Images of", selection: $source) {
                    ForEach(sources, id: \.id) { source in
                        Text(source.name).tag(Optional(source.id))
                    }
                }
                // Not .fixedSize(): a long name (three labels and a catalog number) would make
                // the sheet wider than its window. The button truncates the name; the menu and
                // the tooltip show it whole.
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(sources.first { $0.id == (source ?? release.id) }?.name ?? "")
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let failure, images != nil {
                Text(failure).font(.callout).foregroundStyle(Theme.warning)
            }
            if let plan = sleevePlan {
                Text(plan.text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(plan.details)
            }
            HStack {
                Link(
                    "Open in MusicBrainz",
                    destination: URL(string: "https://musicbrainz.org/release/\(source ?? release.id)/cover-art")!
                )
                .font(.callout)
                Spacer()
                if downloading { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if sleevePlan != nil {
                    Button("Use Each Disc's Sleeve") {
                        choose(.discSleeves)
                        dismiss()
                    }
                    .disabled(downloading)
                    .help(sleevePlan?.details ?? "")
                }
                Button("Use This Cover") { use() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || downloading)
            }
        }
        .padding(20)
        .frame(width: 720, height: 560)
        .task { await findGroupChoice() }
        .task(id: source) { await load() }
    }

    /// True while this release's own images show.
    private var showsOwn: Bool { (source ?? release.id) == release.id }

    private var introduction: String {
        showsOwn
            ? "The images that MusicBrainz editors uploaded for \(release.title). The main front is the one Silverside uses by itself; the cover you choose is kept for the release, so every disc of a set gets it."
            : "The images of another release of \(release.title). Its main front makes all of its images this release's artwork, as if they were its own; another image becomes your cover. Either is kept for the release."
    }

    /// This release, the others, and the release group's choice, each with a name that tells them apart.
    private var sources: [(id: String, name: String)] {
        var seen = Set<String>()
        var list = [(id: String, name: String)]()
        for (index, other) in ([release] + others).enumerated() where !other.isManual && seen.insert(other.id).inserted
        {
            list.append((other.id, (index == 0 ? "This release" : other.title) + Self.edition(of: other)))
        }
        if let groupChoice, seen.insert(groupChoice).inserted {
            list.append((groupChoice, "The release the Cover Art Archive shows for the album"))
        }
        return list
    }

    /// " (Or Music OR805022, US, 2005-04-19, 3 images)". Labels that share a catalog number
    /// name it once: "Columbia, Legacy, Sony Music 88875079792".
    private static func edition(of release: MusicBrainzRelease) -> String {
        var numbers = [String?]()
        var names = [String?: [String]]()
        for label in release.labels {
            if !numbers.contains(label.catalogNumber) { numbers.append(label.catalogNumber) }
            if let name = label.name { names[label.catalogNumber, default: []].append(name) }
        }
        let labels = numbers.map { number in
            ((names[number] ?? []).joined(separator: ", ") + " " + (number ?? "")).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        var parts = labels + [release.country, release.date].compactMap { $0 }
        if let count = release.artworkCount { parts.append(count == 0 ? "no images" : Format.count(count, "image")) }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    /// The release the archive takes for the album's release group, and the release to start
    /// with: another's when asked, or when this one has no images.
    private func findGroupChoice() async {
        let wantsOther = startsWithOthers || !release.hasArtwork
        if let startsWith {
            source = startsWith
        } else if !wantsOther {
            source = release.id
        } else if let other = others.first(where: { $0.id != release.id && !$0.isManual && $0.hasArtwork }) {
            source = other.id
        }
        if let group = release.releaseGroup?.id,
            let found = try? await CoverArtClient().releaseGroupArtwork(releaseGroupID: group)
        {
            groupChoice = found.releaseID
        }
        if source == nil { source = groupChoice ?? release.id }
    }

    @ViewBuilder private var content: some View {
        if let images, images.isEmpty {
            Text(
                "The Cover Art Archive has no images for this release."
                    + (sources.count > 1 ? " Choose another release above." : "")
            )
            .foregroundStyle(.secondary)
        } else if let images {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 14)], spacing: 14) {
                    ForEach(images) { image in
                        cell(image)
                            .onTapGesture { selected = image.id }
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded {
                                    selected = image.id
                                    use()
                                })
                    }
                }
                .padding(4)
            }
        } else if let failure {
            Text(failure).foregroundStyle(Theme.warning)
        } else {
            ProgressView("Asking the Cover Art Archive…")
        }
    }

    private func cell(_ image: CoverArtImage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let data = thumbnails[image.id], let picture = NSImage(data: data) {
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit)
                } else if missingThumbnails.contains(image.id) {
                    Color.secondary.opacity(0.12).overlay {
                        Image(systemName: "photo.badge.exclamationmark").font(.title).foregroundStyle(.secondary)
                    }
                    .help(
                        "The Cover Art Archive did not send this image's thumbnail. Use This Cover tries the full image."
                    )
                } else {
                    Color.secondary.opacity(0.12).overlay { ProgressView().controlSize(.small) }
                }
            }
            .frame(width: 150, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected == image.id ? Color.accentColor : .clear, lineWidth: 3)
            }
            HStack(spacing: 4) {
                Text(image.types.isEmpty ? "Image" : image.types.joined(separator: ", "))
                    .font(.callout.weight(.medium))
                if image.isFront { Chip(text: "Main", tone: .good) }
                if let disc, image.mediums?.contains(disc) == true { Chip(text: "This disc", tone: .good) }
            }
            if !image.comment.isEmpty {
                Text(image.comment).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    .help(image.comment)
            }
        }
        .frame(width: 160, alignment: .topLeading)
        .contentShape(Rectangle())
    }

    /// For a set whose discs have their own sleeves in the archive: which disc takes which,
    /// in one line and in full.
    private var sleevePlan: (text: String, details: String)? {
        let positions = release.cdPositions
        guard positions.count > 1, showsOwn, let images else { return nil }
        let plan = CoverArtImage.sleeves(for: positions, in: images)
        guard !plan.sleeves.isEmpty else { return nil }
        let named = plan.sleeves.map { Self.discs($0.discs) }.joined(separator: ", ")
        var text =
            "\(Format.count(plan.sleeves.count, "sleeve")) \(plan.sleeves.count == 1 ? "names" : "name")"
            + " the discs \(plan.sleeves.count == 1 ? "it is" : "they are") for (\(named))."
        text +=
            plan.others.isEmpty
            ? " Use Each Disc's Sleeve gives every disc its own."
            : " Use Each Disc's Sleeve gives those discs their own; \(Self.discs(plan.others)) keep the set's cover."
        let details = plan.sleeves.map { "\(Self.discs($0.discs)): \($0.image.comment)" }.joined(separator: "\n")
        return (text, details)
    }

    /// "disc 3", "discs 1–2", "discs 1, 4, and 9".
    private static func discs(_ positions: [Int]) -> String {
        if positions.count == 1 { return "disc \(positions[0])" }
        if let first = positions.first, let last = positions.last, positions == Array(first...last) {
            return "discs \(first)–\(last)"
        }
        return "discs " + ListFormatter.localizedString(byJoining: positions.map(String.init))
    }

    /// The list, with the main front and then this disc's images first, then the thumbnails in that order, four at a
    /// time (the web client still spaces the requests as the archive asks), each shown as it comes.
    private func load() async {
        guard let source else { return }
        images = nil
        selected = nil
        failure = nil
        do {
            let found = CoverArtImage.ordered(
                try await CoverArtClient().images(releaseID: source), forDisc: showsOwn ? disc : nil)
            guard source == self.source else { return }
            images = found
            await withTaskGroup(of: (String, Data?).self) { group in
                var waiting = found[...]
                func add() {
                    guard let image = waiting.popFirst() else { return }
                    group.addTask { (image.id, try? await CoverArtClient().thumbnail(image)) }
                }
                for _ in 0..<4 { add() }
                while let (id, data) = await group.next() {
                    if let data { thumbnails[id] = data } else { missingThumbnails.insert(id) }
                    add()
                }
            }
        } catch {
            failure = Self.problem(error, with: "The images could not be listed")
        }
    }

    /// Why the archive gave nothing, for people: "The images could not be listed: …".
    static func problem(_ error: any Error, with start: String) -> String {
        if case .httpStatus(let status, _) = error as? OnlineLookupError, status >= 500 {
            return start + ": the Cover Art Archive answered with an error (HTTP \(status)). Its images are stored "
                + "at the Internet Archive (archive.org), which sometimes cannot send a release's images for hours "
                + "or days. Try again later, or use your own image: drop it on the cover, or choose Choose Cover…."
        }
        if let error = error as? URLError, error.code == .timedOut {
            return start + ": the Cover Art Archive did not answer in time. Try again later."
        }
        return start + ": " + ((error as? URLError)?.localizedDescription ?? "\(error)")
    }

    /// Downloads the chosen image at full size; this release's main front is the archive's
    /// own choice, and another release's makes that release's images the artwork.
    private func use() {
        guard let image = images?.first(where: { $0.id == selected }), let source, !downloading else { return }
        if image.isFront && showsOwn {
            choose(.image(nil))
            dismiss()
            return
        }
        downloading = true
        Task {
            defer { downloading = false }
            do {
                guard let cover = try await CoverArtClient().download(image) else {
                    failure = "The Cover Art Archive no longer has this image."
                    return
                }
                choose(image.isFront ? .release(source, front: cover) : .image(cover))
                dismiss()
            } catch {
                failure = Self.problem(error, with: "The image could not be downloaded")
            }
        }
    }
}

/// A badge on a cover when the Cover Art Archive has more than one image for the release,
/// such as a digital release's art or a box set's sleeves, or for the other release whose
/// images stand for it. It opens the picker, which the cover's menu has too.
struct CoverArchiveBadge: View {
    let release: MusicBrainzRelease?
    /// The other release whose images the cover shows, and their number.
    var otherRelease: String? = nil
    var otherCount: Int? = nil
    var action: () -> Void

    private var count: Int? {
        guard let release, !release.isManual else { return nil }
        if otherRelease != nil { return otherCount }
        return release.hasArtwork ? release.artworkCount : nil
    }

    var body: some View {
        if let count, count > 1 {
            Button(action: action) {
                Label(String(count), systemImage: "photo.stack")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.6), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(5)
            .help(
                otherRelease != nil
                    ? "\(count) images of another release in the Cover Art Archive. Click to see them, and the other releases'."
                    : "\(count) images in the Cover Art Archive. Click to see them and choose the cover.")
        }
    }
}

/// An offer to put a release's other images (back, booklet, medium, and so on) in earlier
/// rips' Artwork folders: after their cover became another release's front, or from
/// Download Artwork… in the cover's menu.
struct ArtworkOffer: Identifiable {
    let id = UUID()
    /// The release's listing, its main front among them: it is the cover, so it is not saved again.
    var images: [CoverArtImage]
    var rips: [RecentRip]
    /// The images in the Artwork folders now (the most in any of them).
    var existing: Int
    /// The offer follows a new cover; else Download Artwork… asked for it.
    var afterCover: Bool

    /// Nil when the release has no image but its main front.
    init?(images: [CoverArtImage], rips: [RecentRip], afterCover: Bool) {
        guard images.contains(where: { !$0.isFront }) else { return nil }
        self.images = images
        self.rips = rips
        self.afterCover = afterCover
        existing = Self.folders(of: rips).map(ArtworkFolder.count(in:)).max() ?? 0
    }

    /// The folders that hold the rips' artwork: each rip's, and its album folder in the library.
    static func folders(of rips: [RecentRip]) -> [URL] {
        rips.filter { !$0.isMissing }.flatMap { rip in
            [rip.folder] + (rip.report.encoding.map { [URL(filePath: $0.folder, directoryHint: .isDirectory)] } ?? [])
        }
    }

    var others: Int { images.filter { !$0.isFront }.count }

    var title: String { afterCover ? "Save that release's other images too?" : "Download the artwork?" }

    var message: String {
        let kinds = Array(Set(images.filter { !$0.isFront }.compactMap { $0.types.first?.lowercased() })).sorted()
        var text = "The Cover Art Archive has \(Format.count(others, "other image"))"
        if !kinds.isEmpty { text += " (" + ListFormatter.localizedString(byJoining: kinds) + ")" }
        text += ". They go in the Artwork folder of the rip and of the album"
        text += existing > 0 ? ", in place of the \(Format.count(existing, "image")) there now." : "."
        return text
    }
}
