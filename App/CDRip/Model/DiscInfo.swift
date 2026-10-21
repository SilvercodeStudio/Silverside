import CDRipKit
import Foundation

/// A disc in a drive: what the disc says of itself, and what MusicBrainz says of it.
struct DiscInfo {
    struct Track: Identifiable {
        let number: Int
        var title: String
        /// The track's artist, if it is not the album's.
        var artist: String?
        var sectors: Int
        var isrc: String?
        var id: Int { number }

        var duration: String { Format.duration(sectors: sectors) }
    }

    /// What a read of the disc gives, from the reading thread.
    struct Read: Sendable {
        var toc: TOC
        var mcn: String?
        var cdText: CDText?
    }

    /// Where the names on show come from.
    enum Source: Hashable {
        case musicBrainz
        case cdText
    }

    enum LookupState: Equatable {
        case notLookedUp
        case lookingUp
        case found
        case notFound
        case failed(String)
    }

    var bsdName: String?
    var toc: TOC
    var mcn: String?
    var cdText: CDText?
    var lookup = LookupState.notLookedUp
    /// The releases that have the disc, the most likely first.
    var releases: [MusicBrainzRelease] = []
    var release: MusicBrainzRelease?
    var medium: MusicBrainzRelease.Medium?
    /// MusicBrainz does not know the disc ID; `releases` have nearly the same TOC.
    var isFuzzy = false
    /// The ranking could not settle on a release, and the user has not chosen one.
    var isAmbiguous = false
    var cover: Data?

    init(bsdName: String?, toc: TOC, mcn: String?, cdText: CDText?) {
        self.bsdName = bsdName
        self.toc = toc
        self.mcn = mcn
        self.cdText = cdText
    }

    /// True if the disc has CD-Text with at least one name.
    var hasCDText: Bool {
        guard let cdText else { return false }
        return !cdText.titles.isEmpty || !cdText.performers.isEmpty
    }

    /// The album's title: from MusicBrainz, else CD-Text, else the disc ID.
    var title: String { title(from: .musicBrainz) }

    var artist: String { artist(from: .musicBrainz) }

    func title(from source: Source) -> String {
        if source == .cdText, let title = cdText?.titles[0] { return title }
        return release?.title ?? cdText?.titles[0] ?? "Audio CD"
    }

    func artist(from source: Source) -> String {
        if source == .cdText, let performer = cdText?.performers[0] { return performer }
        return release?.artist ?? cdText?.performers[0] ?? ""
    }

    /// The release's year, or the year of the release group's first release when this
    /// edition has no date in MusicBrainz (`yearIsFirstRelease`).
    var year: String? {
        (release?.date ?? release?.releaseGroup?.firstReleaseDate).map { String($0.prefix(4)) }
    }

    var yearIsFirstRelease: Bool {
        release?.date == nil && release?.releaseGroup?.firstReleaseDate != nil
    }

    var discLabel: String? {
        guard let release else { return nil }
        guard release.media.count > 1 else { return nil }
        return medium.map { "Disc \($0.position) of \(release.media.count)" } ?? "\(release.media.count) discs"
    }

    var labelText: String? {
        guard let release else { return nil }
        let text = release.labels.compactMap { label in
            [label.name, label.catalogNumber].compactMap { $0 }.joined(separator: " ")
        }.filter { !$0.isEmpty }.joined(separator: ", ")
        return text.isEmpty ? nil : text
    }

    var totalSectors: Int { toc.audioTracks.reduce(0) { $0 + toc.sectorRange(of: $1).count } }

    /// The tracks, named from the release or CD-Text.
    var tracks: [Track] { tracks(from: .musicBrainz) }

    func tracks(from source: Source) -> [Track] {
        toc.audioTracks.enumerated().map { index, track in
            var row = Track(
                number: track.number, title: "Track \(track.number)", sectors: toc.sectorRange(of: track).count)
            if source == .cdText, let title = cdText?.titles[track.number] {
                row.title = title
                if let performer = cdText?.performers[track.number], performer != cdText?.performers[0] {
                    row.artist = performer
                }
            } else if let medium, index < medium.tracks.count {
                let named = medium.tracks[index]
                row.title = named.title
                if let release, named.artist != release.artist { row.artist = named.artist }
            } else if let title = cdText?.titles[track.number] {
                row.title = title
                if let performer = cdText?.performers[track.number], performer != cdText?.performers[0] {
                    row.artist = performer
                }
            }
            return row
        }
    }

    /// Reads the TOC, the MCN, and the CD-Text on a thread of its own: the MCN read takes a
    /// moment, and the drive may not be ready the instant the disc appears.
    nonisolated static func read(makeDrive: @escaping @Sendable () throws -> any CDDrive, bsdName: String) async throws
        -> Read
    {
        var attempt = 0
        while true {
            do {
                return try await Task.detached {
                    let drive = try makeDrive()
                    let toc = try drive.readTOC()
                    let mcn = try? SubchannelCodes.mcn(in: toc, drive: drive)
                    let cdText = (try? drive.readCDText()).flatMap { $0.flatMap(CDText.init(bytes:)) }
                    return Read(toc: toc, mcn: mcn, cdText: cdText)
                }.value
            } catch {
                attempt += 1
                guard attempt < 4 else { throw error }
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Asks MusicBrainz for the disc's releases: one request, kept in the web cache.
    mutating func lookUpRelease() async {
        guard !toc.audioTracks.isEmpty else { return }
        lookup = .lookingUp
        let result: ReleaseLookupResult
        do {
            result = try await ReleaseLookup.find(toc: toc, mcn: mcn)
        } catch {
            lookup = .failed("\(error)")
            return
        }
        releases = result.ranked
        isFuzzy = !result.isExact
        guard let chosen = result.chosen else {
            lookup = .notFound
            release = nil
            medium = nil
            return
        }
        let remembered = ReleaseChoiceStore().choices(forDiscID: toc.musicBrainzDiscID)
        isAmbiguous = ReleaseRanking.isAmbiguous(result.ranked, mcn: mcn, chosen: remembered)
        lookup = .found
        await use(chosen)
    }

    /// Uses a release the user chose, and remembers it for the other discs of the release.
    mutating func choose(_ chosen: MusicBrainzRelease) async {
        try? ReleaseChoiceStore().remember(chosen)
        isAmbiguous = false
        await use(chosen)
    }

    private mutating func use(_ chosen: MusicBrainzRelease) async {
        release = chosen
        medium = chosen.medium(for: toc) ?? (chosen.media.count == 1 ? chosen.media.first : nil)
        cover = nil
        guard chosen.hasFrontCover else { return }
        cover = try? await CoverArtClient().frontCover(releaseID: chosen.id)?.data
    }
}

/// Text for people, as the design shows it.
enum Format {
    /// "9:22" for a track, or "1:12:05" for a long one.
    static func duration(sectors: Int) -> String {
        duration(seconds: sectors / CDDA.sectorsPerSecond)
    }

    static func duration(seconds: Int) -> String {
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// "1 sector", "3 sectors".
    static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)" + (number == 1 ? "" : "s")
    }

    /// "about 3 min left", "about 40 s left".
    static func timeLeft(seconds: Int) -> String {
        if seconds >= 90 { return "about \(Int((Double(seconds) / 60).rounded())) min left" }
        return "about \(max(seconds, 1)) s left"
    }
}
