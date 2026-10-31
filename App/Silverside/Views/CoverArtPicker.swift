import SilversideKit
import SwiftUI

/// The release's images in the Cover Art Archive, to choose the cover from: the archive's
/// main front is the one Silverside takes by itself, but a release can have better ones,
/// such as the art of a digital release or each disc's sleeve in a box set.
struct CoverArtPickerSheet: View {
    enum Choice {
        /// One cover for every disc: the image, or nil for the archive's main front.
        case image(CoverImage?)
        /// Each disc of the set takes its own sleeve (see `CoverArtImage.sleeve`).
        case discSleeves
    }

    @Environment(\.dismiss) private var dismiss
    let release: MusicBrainzRelease
    /// The disc's position in the release, to mark the sleeves made for it. Nil for a whole set.
    var disc: Int?
    var choose: (Choice) -> Void

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
            Text(
                "The images that MusicBrainz editors uploaded for \(release.title). The main front is the one Silverside uses by itself; the cover you choose is kept for the release, so every disc of a set gets it."
            )
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
                    destination: URL(string: "https://musicbrainz.org/release/\(release.id)/cover-art")!
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
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if let images, images.isEmpty {
            Text("The Cover Art Archive has no images for this release.").foregroundStyle(.secondary)
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
        guard positions.count > 1, let images else { return nil }
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
        do {
            let found = CoverArtImage.ordered(
                try await CoverArtClient().images(releaseID: release.id), forDisc: disc)
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

    /// Downloads the chosen image at full size; the main front is the archive's own choice.
    private func use() {
        guard let image = images?.first(where: { $0.id == selected }), !downloading else { return }
        if image.isFront {
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
                choose(.image(cover))
                dismiss()
            } catch {
                failure = Self.problem(error, with: "The image could not be downloaded")
            }
        }
    }
}

/// A badge on a cover when the Cover Art Archive has more than one image for the release,
/// such as a digital release's art or a box set's sleeves. It opens the picker, which the
/// cover's menu has too.
struct CoverArchiveBadge: View {
    let release: MusicBrainzRelease?
    var action: () -> Void

    var body: some View {
        if let release, release.hasArtwork, let count = release.artworkCount, count > 1 {
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
            .help("\(count) images in the Cover Art Archive. Click to see them and choose the cover.")
        }
    }
}
