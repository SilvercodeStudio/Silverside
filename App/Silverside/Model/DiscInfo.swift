import Foundation
import SilversideKit

/// A disc in a drive: what the disc says of itself, and what MusicBrainz says of it.
struct DiscInfo {
    struct Track: Identifiable {
        let number: Int
        var title: String
        /// The track's artist, if it is not the album's.
        var artist: String?
        var sectors: Int
        var isrc: String?
        /// From MusicBrainz's relationships, when it has them.
        var composers: [MusicBrainzRelease.Writer] = []
        var lyricists: [MusicBrainzRelease.Writer] = []
        var recordingID: String?
        var id: Int { number }

        var duration: String { Format.duration(sectors: sectors) }
    }

    /// What a read of the disc gives, from the reading thread.
    struct Read: Sendable {
        var toc: TOC
        var mcn: String?
        var cdText: CDText?
        var media: DiscMediaType?
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
    /// Pressed, CD-R, or CD-RW, if the drive could tell.
    var media: DiscMediaType?
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
    /// A cover the user dropped or chose for this rip, used in place of the Cover Art Archive's.
    var userCover: CoverImage?
    /// A cover chosen for the release before, on another disc or rip; the rip finds it itself.
    var keptCover: CoverImage?
    /// This disc's own sleeve, for a box set whose discs take theirs from the Cover Art Archive.
    var sleeve: CoverImage?
    /// The cover to show: the one the rip's files will embed.
    var shownCover: Data? { (userCover ?? sleeve ?? keptCover)?.data ?? cover }
    /// A release Silverside made, when MusicBrainz has none: from CD-Text, or "Unknown".
    var manual: MusicBrainzRelease?
    /// The user's changes to the names, kept with the rip and, for the album, for the release.
    var edits = MetadataEdits()

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

    /// The release as MusicBrainz or Silverside made it, before the edits.
    var baseRelease: MusicBrainzRelease? { release ?? manual }

    /// The release with the edits applied: what the rip names and tags the files with.
    var shownRelease: MusicBrainzRelease? { baseRelease.map { edits.applied(to: $0, toc: toc) } }

    /// The disc's medium in `shownRelease`.
    var shownMedium: MusicBrainzRelease.Medium? {
        guard let shown = shownRelease else { return nil }
        if let found = shown.medium(for: toc) { return found }
        return medium.flatMap { known in shown.media.first { $0.position == known.position } }
    }

    /// The album's title: from MusicBrainz, else CD-Text, else the disc ID.
    var title: String { title(from: .musicBrainz) }

    var artist: String { artist(from: .musicBrainz) }

    func title(from source: Source) -> String {
        if source == .cdText, let title = cdText?.titles[0] { return title }
        return shownRelease?.title ?? cdText?.titles[0] ?? "Audio CD"
    }

    func artist(from source: Source) -> String {
        if source == .cdText, let performer = cdText?.performers[0] { return performer }
        return shownRelease?.artist ?? cdText?.performers[0] ?? ""
    }

    /// A track's title before the edits, for the table's editing.
    func baseTitle(ofTrack number: Int) -> String? {
        guard let base = baseRelease, let index = toc.audioTracks.firstIndex(where: { $0.number == number }) else {
            return nil
        }
        let medium =
            base.medium(for: toc) ?? medium.flatMap { known in base.media.first { $0.position == known.position } }
        guard let medium, index < medium.tracks.count else { return nil }
        return medium.tracks[index].title
    }

    /// The track's artist as the release has it, before any edit.
    func baseArtist(ofTrack number: Int) -> String? {
        guard let base = baseRelease, let index = toc.audioTracks.firstIndex(where: { $0.number == number }) else {
            return nil
        }
        let medium =
            base.medium(for: toc) ?? medium.flatMap { known in base.media.first { $0.position == known.position } }
        guard let medium, index < medium.tracks.count else { return nil }
        return medium.tracks[index].artist
    }

    /// The release's year, or the year of the release group's first release when this
    /// edition has no date in MusicBrainz (`yearIsFirstRelease`).
    var year: String? {
        (shownRelease?.date ?? release?.releaseGroup?.firstReleaseDate).map { String($0.prefix(4)) }
    }

    var yearIsFirstRelease: Bool {
        shownRelease?.date == nil && release?.releaseGroup?.firstReleaseDate != nil
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
            } else if let medium = shownMedium, index < medium.tracks.count {
                let named = medium.tracks[index]
                row.title = named.title
                if let shown = shownRelease, named.artist != shown.artist { row.artist = named.artist }
                row.composers = named.composers
                row.lyricists = named.lyricists
                row.recordingID = named.recordingID
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
                    let media = (try? drive.readMediaType()) ?? nil
                    return Read(toc: toc, mcn: mcn, cdText: cdText, media: media)
                }.value
            } catch {
                attempt += 1
                guard attempt < 4 else { throw error }
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Asks MusicBrainz for the disc's releases, and for the chosen one's details (the
    /// composers, the genre): two requests, kept in the web cache, so the rip sends none.
    mutating func lookUpRelease() async {
        guard !toc.audioTracks.isEmpty else { return }
        lookup = .lookingUp
        let result: ReleaseLookupResult
        do {
            result = try await ReleaseLookup.find(toc: toc, mcn: mcn, details: true)
        } catch {
            lookup = .failed("\(error)")
            if release == nil { useManualRelease() }
            return
        }
        releases = result.ranked
        isFuzzy = !result.isExact
        guard let chosen = result.chosen else {
            lookup = .notFound
            release = nil
            useManualRelease()
            return
        }
        let remembered = ReleaseChoiceStore().choices(forDiscID: toc.musicBrainzDiscID)
        isAmbiguous = ReleaseRanking.isAmbiguous(
            result.ranked, mcn: mcn, chosen: remembered, chosenForOtherDiscs: ReleaseChoiceStore().allChoices())
        lookup = .found
        await use(chosen)
    }

    /// Uses a release the user chose, and remembers it for the other discs of the release.
    mutating func choose(_ chosen: MusicBrainzRelease) async {
        try? ReleaseChoiceStore().remember(chosen)
        isAmbiguous = false
        // The picker's releases are the lookup's summaries; the details come by ID.
        let detailed = (try? await MusicBrainzClient().release(id: chosen.id)) ?? nil
        await use(detailed ?? chosen)
    }

    /// Without a release, the names come from CD-Text or are typed in, and the files get no MusicBrainz IDs.
    private mutating func useManualRelease() {
        let made = MusicBrainzRelease.manual(toc: toc, cdText: cdText)
        manual = made
        medium = made.media.first
        edits = MetadataEdits()
    }

    private mutating func use(_ chosen: MusicBrainzRelease) async {
        release = chosen
        manual = nil
        medium = chosen.medium(for: toc) ?? (chosen.media.count == 1 ? chosen.media.first : nil)
        edits = ReleaseEditsStore().edits(forReleaseID: chosen.id) ?? MetadataEdits()
        // A cover chosen for this release before, on another disc or rip.
        keptCover = chosen.isManual ? nil : ReleaseCoverStore().cover(forReleaseID: chosen.id)
        cover = nil
        await loadSleeve()
        guard chosen.hasFrontCover else { return }
        cover = try? await CoverArtClient().frontCover(releaseID: chosen.id)?.data
    }

    /// This disc's sleeve, if its release's discs take their own (see `ReleaseCoverStore`).
    mutating func loadSleeve() async {
        sleeve = nil
        guard let release, !release.isManual, let position = medium?.position,
            ReleaseCoverStore().usesDiscSleeves(releaseID: release.id)
        else { return }
        sleeve = try? await CoverArtClient().discSleeve(releaseID: release.id, disc: position)
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
