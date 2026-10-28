import Foundation

/// The discs of one multi-disc release among earlier rips, so that the app can say which
/// discs of a set are ripped, which are verified and encoded, and which are still to do. A
/// release of one disc is not a set. Only the release's CDs count: a box set's DVD is not a
/// disc to rip.
public struct RipSet: Equatable, Sendable {
    /// One ripped disc of the set: the newest rip of it.
    public struct Disc: Equatable, Sendable {
        public var position: Int
        /// The rip's folder, or the album folder for a report kept in the library.
        public var folder: URL
        /// The report file: `disc.json`, or the album folder's copy.
        public var file: URL
        public var date: Date
        /// True while the rip's WAV files are there (in the rips folder).
        public var hasAudio: Bool
        /// AccurateRip or CTDB proves every track.
        public var isVerified: Bool
        /// The rip went into the library.
        public var isEncoded: Bool

        public init(
            position: Int, folder: URL, file: URL, date: Date, hasAudio: Bool, isVerified: Bool, isEncoded: Bool
        ) {
            self.position = position
            self.folder = folder
            self.file = file
            self.date = date
            self.hasAudio = hasAudio
            self.isVerified = isVerified
            self.isEncoded = isEncoded
        }

        public var isFinished: Bool { isVerified && isEncoded }

        /// "verified and encoded", "verified, not encoded", "encoded, not verified", "not verified".
        public var stateText: String {
            switch (isVerified, isEncoded) {
            case (true, true): "verified and encoded"
            case (true, false): "verified, not encoded"
            case (false, true): "encoded, not verified"
            case (false, false): "ripped, not verified"
            }
        }
    }

    public var releaseID: String
    public var title: String
    public var artist: String
    /// The positions of the release's CDs, in order.
    public var positions: [Int]
    /// The ripped discs, by position.
    public var discs: [Int: Disc]

    public init(releaseID: String, title: String, artist: String, positions: [Int], discs: [Int: Disc] = [:]) {
        self.releaseID = releaseID
        self.title = title
        self.artist = artist
        self.positions = positions
        self.discs = discs
    }

    /// How many CDs the release has.
    public var discCount: Int { positions.count }

    /// The positions of the discs that are not ripped yet.
    public var missing: [Int] { positions.filter { discs[$0] == nil } }

    /// Ripped discs that are not yet verified and encoded.
    public var unfinished: [Int] { discs.values.filter { !$0.isFinished }.map(\.position).sorted() }

    /// Every disc ripped, verified, and encoded.
    public var isComplete: Bool { missing.isEmpty && unfinished.isEmpty }

    /// "Discs 1 and 3 of 3 ripped; disc 2 still to do; disc 1 not verified", for people to read.
    public var summary: String {
        let ripped = discs.keys.sorted()
        if isComplete { return "All \(discCount) discs verified and encoded" }
        var text =
            ripped.isEmpty
            ? "No disc of \(discCount) ripped yet"
            : "\(ripped.count == 1 ? "Disc" : "Discs") \(Self.list(ripped)) of \(discCount) ripped"
        if !missing.isEmpty { text += "; \(missing.count == 1 ? "disc" : "discs") \(Self.list(missing)) still to do" }
        let notVerified = discs.values.filter { !$0.isVerified }.map(\.position).sorted()
        let notEncoded = discs.values.filter { $0.isVerified && !$0.isEncoded }.map(\.position).sorted()
        if !notVerified.isEmpty {
            text += "; \(notVerified.count == 1 ? "disc" : "discs") \(Self.list(notVerified)) not verified"
        }
        if !notEncoded.isEmpty {
            text += "; \(notEncoded.count == 1 ? "disc" : "discs") \(Self.list(notEncoded)) not encoded"
        }
        return text
    }

    /// "1", "1 and 3", "1, 2, and 4".
    public static func list(_ numbers: [Int]) -> String {
        list(numbers.map(String.init))
    }

    /// "a", "a and b", "a, b, and c".
    public static func list(_ words: [String]) -> String {
        switch words.count {
        case 0: return ""
        case 1: return words[0]
        case 2: return "\(words[0]) and \(words[1])"
        default: return words.dropLast().joined(separator: ", ") + ", and " + words[words.count - 1]
        }
    }

    /// An earlier rip, as the sets are found from it.
    public struct Rip: Sendable {
        public var folder: URL
        public var file: URL
        public var report: RipReport
        public var hasAudio: Bool

        public init(folder: URL, file: URL, report: RipReport, hasAudio: Bool) {
            self.folder = folder
            self.file = file
            self.report = report
            self.hasAudio = hasAudio
        }
    }

    /// The sets among earlier rips: one for each release with more than one CD, with the
    /// newest rip of each disc. Rips with no release, or of a one-CD release, are left out.
    public static func sets(in rips: [Rip]) -> [RipSet] {
        var sets = [String: RipSet]()
        for rip in rips.sorted(by: { $0.report.date > $1.report.date }) {
            guard let release = rip.report.release, !release.isManual, release.cdPositions.count > 1,
                let position = rip.report.discPosition
            else { continue }
            var set =
                sets[release.id]
                ?? RipSet(
                    releaseID: release.id, title: release.title, artist: release.artist,
                    positions: release.cdPositions)
            if let known = set.discs[position], known.date >= rip.report.date { continue }
            set.discs[position] = Disc(
                position: position, folder: rip.folder, file: rip.file, date: rip.report.date, hasAudio: rip.hasAudio,
                isVerified: rip.report.isVerified, isEncoded: rip.report.encoding != nil || !rip.hasAudio)
            sets[release.id] = set
        }
        return sets.values.sorted { ($0.artist, $0.title) < ($1.artist, $1.title) }
    }
}

extension MusicBrainzRelease.Medium {
    /// True for a medium that a CD drive reads as an audio CD: a CD, HDCD, Enhanced CD, CD-R,
    /// hybrid SACD, or DualDisc, and a medium whose format MusicBrainz does not say. Not a
    /// DVD, Blu-ray, vinyl, cassette, download, or SACD-only disc.
    public var isCompactDisc: Bool {
        guard let format = format?.lowercased() else { return true }
        if format.contains("hybrid") || format.contains("dualdisc") { return true }
        for other in ["dvd", "blu-ray", "bluray", "vinyl", "cassette", "digital", "sacd", "minidisc", "file"]
        where format.contains(other) {
            return false
        }
        return true
    }
}

extension MusicBrainzRelease {
    /// The positions of the release's CDs: the discs there are to rip.
    public var cdPositions: [Int] { media.filter(\.isCompactDisc).map(\.position) }
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

/// Where a set's ReplayGain stands. Each disc is measured when it is encoded, and its album
/// gain is its own until every disc of the set is in the album folder; then every disc's files
/// get the album gain over all of them (see `DiscEncoder.updateReleaseGain`).
public struct SetReplayGain: Equatable, Sendable {
    /// Each encoded disc's own album gain, by position; nil for a disc encoded without ReplayGain.
    public var discs: [Int: ReplayGain.Values?]
    /// The album gain over every disc, once each disc's files have it.
    public var whole: ReplayGain.Values?
    public var discCount: Int

    /// The state, as one line for people.
    public var text: String {
        let own = discs.keys.sorted().compactMap { position in
            discs[position]!.map { "disc \(position) \($0.gainText)" }
        }
        if let whole {
            return "Album gain over all \(discCount) discs: \(whole.gainText), peak "
                + String(format: "%.3f", whole.peak) + ". On its own, " + RipSet.list(own) + "."
        }
        if let without = discs.keys.sorted().first(where: { discs[$0]! == nil }) {
            return "Disc \(without) was encoded without ReplayGain, so the set has no album gain over all its discs."
        }
        if discs.count < discCount {
            return "Each disc has its own album gain until all \(discCount) are encoded (\(discs.count) so far):"
                + " " + RipSet.list(own) + ". Then every disc gets the album gain over the whole set."
        }
        return "Each disc has its own album gain: " + RipSet.list(own)
            + ". Update the Library writes the album gain over the whole set."
    }
}

extension RipSet {
    /// The set's ReplayGain, from the reports in its album folder: the first of `folders` (the
    /// album folders that the discs' reports name) that has the release's reports. Nil when no
    /// disc there was encoded with ReplayGain.
    public static func replayGain(of release: MusicBrainzRelease, folders: [URL]) -> SetReplayGain? {
        let positions = release.cdPositions
        for folder in folders {
            let reports = DiscEncoder.albumReports(of: release, in: folder)
            guard !reports.isEmpty else { continue }
            var discs = [Int: ReplayGain.Values?]()
            var wholes = [ReplayGain.Values?]()
            for (_, report) in reports {
                guard let position = report.discPosition, positions.contains(position), let encoding = report.encoding,
                    encoding.albumSuffix == nil
                else { continue }
                discs[position] = encoding.replayGain?.album
                wholes.append(encoding.replayGain?.release)
            }
            guard discs.values.contains(where: { $0 != nil }) else { return nil }
            // The whole set's gain counts once every disc's report has the same one.
            let whole =
                discs.count == positions.count && Set(wholes.map { $0?.gainText }).count == 1 ? wholes.first! : nil
            return SetReplayGain(discs: discs, whole: whole, discCount: positions.count)
        }
        return nil
    }
}
