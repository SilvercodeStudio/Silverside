import Foundation

/// The discs of one multi-disc release among earlier rips, so that the app can say which
/// discs of a set are ripped and which are still to do. A release of one disc is not a set.
public struct RipSet: Equatable, Sendable {
    public var releaseID: String
    public var title: String
    public var artist: String
    public var discCount: Int
    /// The rip folder of each ripped disc, by the disc's position in the release.
    public var discs: [Int: URL]

    public init(releaseID: String, title: String, artist: String, discCount: Int, discs: [Int: URL]) {
        self.releaseID = releaseID
        self.title = title
        self.artist = artist
        self.discCount = discCount
        self.discs = discs
    }

    /// The positions of the discs that are not ripped yet.
    public var missing: [Int] { (1...max(discCount, 1)).filter { discs[$0] == nil } }

    public var isComplete: Bool { missing.isEmpty }

    /// "Discs 1 and 3 of 3 ripped; disc 2 is still to do", for people to read.
    public var summary: String {
        let ripped = discs.keys.sorted()
        if isComplete { return "All \(discCount) discs ripped" }
        let rippedText =
            ripped.isEmpty
            ? "No disc of \(discCount) ripped yet"
            : "\(ripped.count == 1 ? "Disc" : "Discs") \(Self.list(ripped)) of \(discCount) ripped"
        return rippedText + "; \(missing.count == 1 ? "disc" : "discs") \(Self.list(missing)) still to do"
    }

    /// "1", "1 and 3", "1, 2, and 4".
    static func list(_ numbers: [Int]) -> String {
        let words = numbers.map(String.init)
        switch words.count {
        case 0: return ""
        case 1: return words[0]
        case 2: return "\(words[0]) and \(words[1])"
        default: return words.dropLast().joined(separator: ", ") + ", and " + words[words.count - 1]
        }
    }

    /// The sets among earlier rips: one for each multi-disc release, with the newest rip of
    /// each disc. Rips with no release, or of a one-disc release, are left out.
    public static func sets(in rips: [(folder: URL, report: RipReport)]) -> [RipSet] {
        var sets = [String: RipSet]()
        var dates = [String: [Int: Date]]()
        for rip in rips.sorted(by: { $0.report.date > $1.report.date }) {
            guard let release = rip.report.release, release.media.count > 1, !release.isManual,
                let position = rip.report.discPosition
            else { continue }
            var set =
                sets[release.id]
                ?? RipSet(
                    releaseID: release.id, title: release.title, artist: release.artist,
                    discCount: release.media.count, discs: [:])
            if let known = dates[release.id]?[position], known >= rip.report.date { continue }
            set.discs[position] = rip.folder
            dates[release.id, default: [:]][position] = rip.report.date
            sets[release.id] = set
        }
        return sets.values.sorted { ($0.artist, $0.title) < ($1.artist, $1.title) }
    }
}

extension RipReport {
    /// The release's medium that the rip's disc is, if the report has a release.
    public var medium: MusicBrainzRelease.Medium? {
        guard let release, let toc = try? TOC(ctdbTOCString: toc) else { return nil }
        return release.medium(for: toc) ?? (release.media.count == 1 ? release.media.first : nil)
    }

    /// The disc's position in its release: 2 for disc 2 of 3.
    public var discPosition: Int? { medium?.position }
}
