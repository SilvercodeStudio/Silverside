import Foundation

/// What to do with a CD+G disc's graphics after a rip: a video of them, with the audio as
/// Apple Lossless or AAC, or none.
public enum CDGraphicsVideoChoice: String, Codable, CaseIterable, Sendable {
    /// The app asks when a rip of such a disc starts; the command line asks at a terminal, and makes none otherwise.
    case ask
    case appleLossless
    case aac
    case none

    /// The video's audio, or nil for none (and for ask, which is not an answer).
    public var audio: CDGraphicsVideo.Audio? {
        switch self {
        case .appleLossless: .appleLossless
        case .aac: .aac
        case .ask, .none: nil
        }
    }
}

extension CDGraphicsVideo {
    /// The video's name: the album's title, and the disc's number in a set, as the album
    /// folder's report has it: "Information Society.m4v", "Hits (Disc 2).m4v". A CD+EG disc's
    /// CD+G picture is "… (CD+G).m4v". A disc with no release is named `untitled`.
    public static func fileName(
        release: MusicBrainzRelease?, toc: TOC, picture: Picture = .extended, untitled: String = "Disc"
    ) -> String {
        let medium = release?.medium(for: toc)
        let discPart = (release?.media.count ?? 0) > 1 ? medium.map { " (Disc \($0.position))" } ?? "" : ""
        return NameTemplate.safeComponent(release?.title ?? untitled) + discPart
            + (picture == .standard ? " (CD+G)" : "") + ".m4v"
    }

    /// True if any track of the rip has CD+EG graphics, so that its CD+G picture differs.
    public static func hasExtendedGraphics(_ report: RipReport?) -> Bool {
        report?.tracks.contains { $0.graphics?.extended == true } == true
    }

    /// Where a disc's video goes: into the album folder, beside the audio, when the disc is an
    /// album or its rip was encoded and the folder is there with this rip's report; with that
    /// report, which records it. Else into the rip's own folder, with no report to record it: a
    /// folder that now holds another edition's album, or another rip's, is not this rip's.
    public static func destination(of disc: RippedDisc) -> (folder: URL, albumReport: URL?) {
        if disc.isAlbum { return (disc.folder, disc.reportFile) }
        if let encoding = disc.report?.encoding, encoding.albumSuffix == nil {
            let album = URL(filePath: encoding.folder, directoryHint: .isDirectory)
            let discPart =
                (disc.release?.media.count ?? 0) > 1
                ? disc.release?.medium(for: disc.toc).map { " (Disc \($0.position))" } ?? "" : ""
            let report = album.appending(path: "Rip Report\(discPart).json")
            if let own = disc.report, let there = try? RipReport.read(from: report),
                there.release?.id == own.release?.id, RipHistory.sameRip(there, own)
            {
                return (album, report)
            }
        }
        return (disc.folder, nil)
    }

    /// Writes the video of a ripped disc (a rip, or an album with its graphics beside its
    /// files) in `picture`, where `destination(of:)` says, and returns the file. The album's
    /// report records it (`RipReport.Encoding.videos`), so that the library's updates rename it
    /// with the album, and a video of the same picture under an older name goes. Throws if no
    /// track has graphics.
    public func write(_ disc: RippedDisc, stop: StopToken? = nil, progress: (Double) -> Void = { _ in }) throws -> URL {
        let chapters = try Self.chapters(of: disc)
        let (folder, albumReport) = Self.destination(of: disc)
        // A rip with no release takes its folder's name.
        let url = folder.appending(
            path: Self.fileName(
                release: disc.release, toc: disc.toc, picture: picture, untitled: disc.folder.lastPathComponent))
        var video = self
        video.title = video.title ?? disc.release?.title
        video.artist = video.artist ?? disc.release?.artist
        try video.write(chapters, to: url, stop: stop, progress: progress)
        guard let albumReport else { return url }
        let entry = RipReport.Encoding.Video(file: url.lastPathComponent, picture: picture)
        func record(_ encoding: inout RipReport.Encoding?) -> [String] {
            let videos = encoding?.videos ?? []
            encoding?.videos = (videos.filter { $0.picture != picture } + [entry])
                .sorted { $0.picture == .extended && $1.picture != .extended }
            return videos.filter { $0.picture == picture && $0.file != entry.file }.map(\.file)
        }
        var older = [String]()
        var report = try RipReport.update(reportAt: albumReport) { older = record(&$0.encoding) }
        for name in older { try? FileManager.default.removeItem(at: folder.appending(path: name)) }
        // The rip's own report, while it is kept, says the same of its encoding.
        if !disc.isAlbum, disc.report?.encoding != nil {
            _ = try RipReport.update(reportAt: disc.reportFile) { _ = record(&$0.encoding) }
        }
        report.release = disc.release ?? report.release
        try report.writeReadable(to: albumReport.deletingPathExtension().appendingPathExtension("md"))
        return url
    }
}
