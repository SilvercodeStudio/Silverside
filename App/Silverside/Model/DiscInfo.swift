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
    /// The other release whose images the user chose for the release (`ReleaseCoverStore.artworkRelease`).
    var artworkRelease: String?
    /// The other release whose images stand for this one: the one chosen, or, for a release
    /// with none, the one the Cover Art Archive takes for its release group. Nil for its own.
    var coverRelease: String?
    /// The number of images of `coverRelease`, for the cover's badge.
    var coverReleaseImages: Int?
    /// `cover` is another release's.
    var coverFromOtherRelease: Bool { coverRelease != nil && cover != nil }
    /// The cover to show: the one the rip's files will embed.
    var shownCover: Data? { (userCover ?? sleeve ?? keptCover)?.data ?? cover }
    /// A release Silverside made, when MusicBrainz has none: from CD-Text, or "Unknown".
    var manual: MusicBrainzRelease?
    /// The user's changes to the names, kept with the rip and, for the album, for the release.
    var edits = MetadataEdits()
    /// For a disc MusicBrainz does not know: the names came from an earlier rip of it.
    var namesFromEarlierRip = false

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
    var shownMedium: MusicBrainzRelease.Medium? { medium(in: shownRelease) }

    /// The disc's medium in `release` (the base release, or the shown one): the one found when
    /// the release was chosen, since edits do not change which it is, else the one the TOC
    /// finds. The view asks for it at every keystroke in a name, so it does not look first.
    private func medium(in release: MusicBrainzRelease?) -> MusicBrainzRelease.Medium? {
        guard let release else { return nil }
        if let known = medium, let found = release.media.first(where: { $0.position == known.position }) {
            return found
        }
        return release.medium(for: toc)
    }

    /// The album's title: from MusicBrainz, else CD-Text, else the disc ID.
    var title: String { title(from: .musicBrainz) }

    var artist: String { artist(from: .musicBrainz) }

    func title(from source: Source) -> String {
        if source == .cdText, let title = cdText?.titles[0] { return title }
        if toc.audioTracks.isEmpty { return "Data Disc" }
        return shownRelease?.title ?? cdText?.titles[0] ?? "Audio CD"
    }

    func artist(from source: Source) -> String {
        if source == .cdText, let performer = cdText?.performers[0] { return performer }
        return shownRelease?.artist ?? cdText?.performers[0] ?? ""
    }

    /// A track's title before the edits, for the table's editing.
    func baseTitle(ofTrack number: Int) -> String? {
        guard let index = toc.audioTracks.firstIndex(where: { $0.number == number }),
            let medium = medium(in: baseRelease), index < medium.tracks.count
        else { return nil }
        return medium.tracks[index].title
    }

    /// The track's artist as the release has it, before any edit.
    func baseArtist(ofTrack number: Int) -> String? {
        guard let index = toc.audioTracks.firstIndex(where: { $0.number == number }),
            let medium = medium(in: baseRelease), index < medium.tracks.count
        else { return nil }
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

    /// "Disc 1 of 2", with the media when some cannot be ripped: "Disc 1 of 2 · CD + Blu-ray".
    /// A mix of kinds of CD, such as "CD + HDCD", is only in the tooltip: MusicBrainz can be
    /// wrong about those, and the rip finds HDCD codes itself.
    var discLabel: String? {
        guard let release, release.media.count > 1 else { return nil }
        let count = release.media.count
        let text = medium.map { "Disc \($0.position) of \(count)" } ?? "\(count) discs"
        return release.media.allSatisfy(\.isCompactDisc) ? text : "\(text) · \(release.formats)"
    }

    var discLabelHelp: String? {
        guard let release, release.media.count > 1 else { return nil }
        let count = release.media.count
        let place =
            medium.map { "This is disc \($0.position) of the \(count) in this release" }
            ?? "This release has \(count) discs"
        guard !release.isCDsOnly else { return place + "." }
        guard !release.media.allSatisfy(\.isCompactDisc) else {
            return place + ". MusicBrainz lists them as \(release.formats)."
        }
        return place + ": \(release.formats). Silverside rips the CDs only. The tags number the discs as "
            + "MusicBrainz does" + (medium.map { ": disc \($0.position) of \(count)." } ?? ".")
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

    /// Row 0 of the track table: the audio before track 1, where a rip may find a hidden track.
    /// It shows when MusicBrainz names a hidden track, the gap is long enough to hold one
    /// (`HiddenTrackRip.likelyGapSectors`), or `found` (a rip kept one or is reading the gap).
    func hiddenTrackRow(found: Bool) -> Track? {
        let sectors = HiddenTrackRip.gapSectors(of: toc)
        let named = medium(in: shownRelease)?.hiddenTrack?.title
        guard sectors > 0, found || named != nil || sectors >= HiddenTrackRip.likelyGapSectors else { return nil }
        return Track(number: 0, title: named ?? "Hidden track", sectors: sectors)
    }

    func tracks(from source: Source) -> [Track] {
        let shownRelease = shownRelease
        let shownMedium = medium(in: shownRelease)
        return toc.audioTracks.enumerated().map { index, track in
            var row = Track(
                number: track.number, title: "Track \(track.number)", sectors: toc.sectorRange(of: track).count)
            if source == .cdText, let title = cdText?.trackTitles[track.number] {
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
            } else if let title = cdText?.trackTitles[track.number] {
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
                    let toc = try drive.readTOCUnlessBlank()
                    let mcn = try? SubchannelCodes.mcn(in: toc, drive: drive)
                    let cdText = (try? drive.readCDText()).flatMap { $0.flatMap(CDText.init(bytes:)) }
                    let media = (try? drive.readMediaType()) ?? nil
                    return Read(toc: toc, mcn: mcn, cdText: cdText, media: media)
                }.value
            } catch {
                attempt += 1
                // A blank disc stays blank.
                if case DriveError.blankDisc? = error as? DriveError { throw error }
                guard attempt < 4 else { throw error }
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Asks MusicBrainz for the disc's releases, and for the chosen one's details (the
    /// composers, the genre): two requests, kept in the web cache, so the rip sends none.
    /// `fresh` asks MusicBrainz again, not the cache (Look Up Metadata): the cache keeps a disc
    /// that MusicBrainz did not know for a day, and a release that was just added should show.
    /// A failed lookup is often brief (the network not yet up after sleep, a busy server), so it
    /// is tried once more after this pause.
    static let retryDelay = Duration.seconds(5)

    mutating func lookUpRelease(fresh: Bool = false) async {
        guard !toc.audioTracks.isEmpty else { return }
        lookup = .lookingUp
        var found: ReleaseLookupResult?
        var failure: (any Error)?
        for attempt in 1...2 {
            do {
                found = try await ReleaseLookup.find(toc: toc, mcn: mcn, details: true, useCache: !fresh)
                break
            } catch {
                failure = error
                guard attempt == 1, (try? await Task.sleep(for: Self.retryDelay)) != nil else { break }
            }
        }
        guard let result = found else {
            lookup = .failed(failure.map { "\($0)" } ?? "unknown error")
            if release == nil { await useManualRelease() }
            return
        }
        releases = result.ranked
        isFuzzy = !result.isExact
        guard let chosen = result.chosen else {
            lookup = .notFound
            release = nil
            await useManualRelease()
            return
        }
        let remembered = ReleaseChoiceStore().choices(forDiscID: toc.musicBrainzDiscID)
        isAmbiguous = ReleaseRanking.isAmbiguous(
            result.ranked, mcn: mcn, chosen: remembered, chosenForOtherDiscs: ReleaseChoiceStore().allChoices())
        lookup = .found
        lookupChoice = chosen
        // A disc the user put in a set of their own is the set's, though MusicBrainz has it.
        if let set = CustomSetStore().set(containing: toc) {
            release = nil
            useCustomSet(set)
            return
        }
        await use(chosen)
    }

    /// The release the lookup chose, kept for a disc in a custom set, to go back to if it leaves the set.
    var lookupChoice: MusicBrainzRelease?

    /// Uses a release the user chose, and remembers it for the other discs of the release. A disc
    /// in a custom set leaves it: the user chose MusicBrainz's release over it.
    mutating func choose(_ chosen: MusicBrainzRelease) async {
        if customSet != nil { try? CustomSetStore().remove(toc) }
        try? ReleaseChoiceStore().remember(chosen)
        isAmbiguous = false
        // The picker's releases are the lookup's summaries; the details come by ID.
        let detailed = (try? await MusicBrainzClient().release(id: chosen.id)) ?? nil
        await use(detailed ?? chosen)
    }

    /// Without a release, the names come from CD-Text or are typed in, and the files get no
    /// MusicBrainz IDs. A disc ripped before with names typed in gets those names, and the cover
    /// of that rip, again.
    private mutating func useManualRelease() async {
        let made = MusicBrainzRelease.manual(toc: toc, cdText: cdText)
        manual = made
        medium = made.media.first
        edits = MetadataEdits()
        namesFromEarlierRip = false
        if let set = CustomSetStore().set(containing: toc) {
            useCustomSet(set)
        } else if userCover == nil {
            // A cover given before a rip that did not finish (`useCover`).
            userCover = ReleaseCoverStore().cover(forReleaseID: made.id)
        }
        let toc = toc
        guard
            let earlier = await Task.detached(operation: { RipHistory().newestNamedRip(of: toc) }).value,
            let names = MetadataEdits.read(fromReportAt: earlier)
        else { return }
        // In a custom set, the album's names are the set's: only the tracks' come from the rip.
        edits = manual?.isCustomSet == true ? edits.merged(with: names.trackLevel) : names
        namesFromEarlierRip = true
        let report = try? RipReport.read(from: earlier)
        if userCover == nil,
            let file = CoverFiles.embedded(forDisc: report?.discPosition, in: earlier.deletingLastPathComponent()),
            let data = try? Data(contentsOf: file)
        {
            userCover = CoverImage(data: data)
        }
    }

    /// The custom set this disc is in, if any.
    var customSet: CustomSet? {
        guard let manual, manual.isCustomSet else { return nil }
        return CustomSetStore().set(id: manual.id)
    }

    /// A custom set made for another disc of the same box, with the place for this one free:
    /// CD-Text's album title, such as "Seven Classic LPs [Disc 2]", names the set and the place.
    var suggestedSet: (set: CustomSet, position: Int)? {
        guard release == nil, manual != nil, customSet == nil, let shown = shownRelease,
            let hint = CDTextHints.disc(inAlbumTitle: cdText?.titles[0] ?? shown.title),
            let set = CustomSetSheet.set(in: CustomSetStore().sets(), named: hint.title, artist: shown.artist),
            hint.position <= set.discCount, set.disc(at: hint.position) == nil
        else { return nil }
        return (set, hint.position)
    }

    /// The disc's own release, as Silverside names it without a set: from CD-Text, or "Track N".
    var singleRelease: MusicBrainzRelease { MusicBrainzRelease.manual(toc: toc, cdText: cdText) }

    /// The disc's tracks as they are named now, for putting it in a set: MusicBrainz's names, if
    /// a release has it, else its own.
    var tracksForSet: [MusicBrainzRelease.Track] {
        if let tracks = medium?.tracks, tracks.count == toc.audioTracks.count { return tracks }
        return singleRelease.media[0].tracks
    }

    /// Names the disc as a disc of `set`, which has it: the set's album names and cover, and the
    /// names already typed for its tracks.
    mutating func useCustomSet(_ set: CustomSet) {
        let release = set.release
        // MusicBrainz's release, if it has the disc, stays in `releases` for Other Releases.
        self.release = nil
        cover = nil
        sleeve = nil
        manual = release
        medium = release.medium(for: toc)
        edits = (ReleaseEditsStore().edits(forReleaseID: release.id) ?? MetadataEdits()).merged(with: edits.trackLevel)
        keptCover = ReleaseCoverStore().cover(forReleaseID: release.id)
    }

    /// Takes the disc out of its custom set: MusicBrainz's release again, if the lookup found one,
    /// else a disc of its own, with the set's names for it as its own, so nothing typed is lost.
    mutating func leaveCustomSet() async {
        guard manual?.isCustomSet == true, let shown = shownRelease else { return }
        try? CustomSetStore().remove(toc)
        if let lookupChoice {
            await use(lookupChoice)
            return
        }
        let single = singleRelease
        manual = single
        medium = single.media.first
        var names = MetadataEdits(album: shown.title, albumArtist: shown.artist).merged(with: edits.trackLevel)
        if names.album == single.title { names.album = nil }
        if names.albumArtist == single.artist { names.albumArtist = nil }
        edits = names
        keptCover = nil
    }

    /// A cover the user dropped or chose: shown now, and kept at once for the release (with
    /// none, for the disc's own manual release), so that it is there again when the disc goes
    /// in again, even if no rip finished to save it.
    mutating func useCover(_ cover: CoverImage) {
        userCover = cover
        if let id = baseRelease?.id { try? ReleaseCoverStore().remember(cover, forReleaseID: id) }
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
        await loadCover()
    }

    /// The archive's cover for the release, and the other release it comes from, if any: the
    /// one the user chose (`ReleaseCoverStore.artworkRelease`), else, for a release with no
    /// images, its release group's (`CoverArtClient.releaseGroupArtwork`).
    mutating func loadCover() async {
        (artworkRelease, coverRelease, coverReleaseImages) = (nil, nil, nil)
        guard let release, !release.isManual else { return }
        artworkRelease = ReleaseCoverStore().artworkRelease(forReleaseID: release.id)
        coverRelease = artworkRelease
        if let other = artworkRelease {
            coverReleaseImages = (try? await CoverArtClient().images(releaseID: other))?.count
        } else if !release.hasFrontCover, let group = release.releaseGroup?.id,
            let found = try? await CoverArtClient().releaseGroupArtwork(releaseGroupID: group),
            found.releaseID != release.id
        {
            coverRelease = found.releaseID
            coverReleaseImages = found.images.count
        }
        let data = await Self.frontCover(of: release, from: coverRelease)
        guard self.release?.id == release.id else { return }
        cover = data
    }

    /// The archive's front cover for the release: `source`'s, its own, or its release group's
    /// (`CoverArtClient.frontCover(of:from:)`). A failed download is tried once more after a
    /// pause: the archive sends its images on to archive.org, which can be slow to answer.
    static func frontCover(of release: MusicBrainzRelease, from source: String? = nil) async -> Data? {
        for attempt in 1...2 {
            do {
                return try await CoverArtClient().frontCover(of: release, from: source)?.data
            } catch {
                guard attempt == 1, !(error is CancellationError), (try? await Task.sleep(for: retryDelay)) != nil
                else { return nil }
            }
        }
        return nil
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
    /// "1 track", "3 tracks"; `plural` for a noun that does not take an s, such as "entries".
    static func count(_ number: Int, _ noun: String, plural: String? = nil) -> String {
        "\(number) " + (number == 1 ? noun : plural ?? noun + "s")
    }

    /// "about 3 min left", "about 40 s left".
    static func timeLeft(seconds: Int) -> String {
        if seconds >= 90 { return "about \(Int((Double(seconds) / 60).rounded())) min left" }
        return "about \(max(seconds, 1)) s left"
    }
}
