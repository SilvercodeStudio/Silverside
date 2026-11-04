import Foundation
import Testing

@testable import SilversideKit

/// Sets of discs that MusicBrainz does not know, made by the user, and what CD-Text says of them.
struct CustomSetTests {
    func store() -> (CustomSetStore, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        return (CustomSetStore(url: root.appending(path: "CustomSets.json")), root)
    }

    @Test func findsTheDiscNumberInAnAlbumTitle() {
        func disc(_ title: String) -> String? {
            CDTextHints.disc(inAlbumTitle: title).map {
                "\($0.title)|\($0.position)|\($0.count.map(String.init) ?? "-")"
            }
        }
        #expect(disc("Seven Classic LPs [Disc 2]") == "Seven Classic LPs|2|-")
        #expect(disc("Live at the Fillmore (CD 1)") == "Live at the Fillmore|1|-")
        #expect(disc("Anthology - Disc 3 of 4") == "Anthology|3|4")
        #expect(disc("Greatest Hits disc2") == "Greatest Hits|2|-")
        #expect(disc("The Wall, Disk 1/2") == "The Wall|1|2")
        #expect(disc("Abbey Road") == nil)
        #expect(disc("Disco Inferno") == nil)
        #expect(disc("Abbacd 2") == nil)
        #expect(disc("Disc 2") == nil)
    }

    @Test func takesTheTrackNumbersOffTitlesThatAllHaveThem() {
        let numbered = [
            0: "Seven Classic LPs [Disc 2]", 1: "01 St. Louis Blues", 2: "02 Bossa Nova U.S.A.",
            10: "10. Castillian Drums",
        ]
        #expect(
            CDTextHints.withoutTrackNumbers(numbered)
                == [
                    0: "Seven Classic LPs [Disc 2]", 1: "St. Louis Blues", 2: "Bossa Nova U.S.A.",
                    10: "Castillian Drums",
                ])
        // A song whose title starts with a number, on a disc whose other titles have none.
        let song = [1: "Intro", 7: "7 Seconds"]
        #expect(CDTextHints.withoutTrackNumbers(song) == song)
        // Another track's number is not this one's.
        let other = [1: "2 Become 1", 2: "02 Wannabe"]
        #expect(CDTextHints.withoutTrackNumbers(other) == other)
        // One title alone is not a pattern.
        #expect(CDTextHints.withoutTrackNumbers([1: "1979"]) == [1: "1979"])
    }

    /// A manual release takes the titles without their numbers.
    @Test func namesAManualDiscWithoutTheNumbers() throws {
        let (toc, _) = try makeDisc(trackSectors: [800, 900])
        var text = CDText()
        text.titles = [0: "Seven Classic LPs [Disc 2]", 1: "01 St. Louis Blues", 2: "02 Bossa Nova U.S.A."]
        let release = MusicBrainzRelease.manual(toc: toc, cdText: text)
        #expect(release.media[0].tracks.map(\.title) == ["St. Louis Blues", "Bossa Nova U.S.A."])
        #expect(release.title == "Seven Classic LPs [Disc 2]")
    }

    /// The set is a release of all its discs, with the ones not put in it yet empty; a disc
    /// put in another set leaves the first.
    @Test func makesAReleaseOfEveryDisc() throws {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        let (disc2, _) = try makeDisc(trackSectors: [800, 900])
        let (disc3, _) = try makeDisc(trackSectors: [700, 600, 500])
        var set = CustomSet(title: "Seven Classic LPs", artist: "Dave Brubeck", discCount: 4)
        #expect(set.id.hasPrefix("silverside:set:") && set.freePositions == [1, 2, 3, 4])
        set.put(disc2, at: 2, namedAs: .manual(toc: disc2))
        set.put(disc3, at: 3, namedAs: .manual(toc: disc3))
        try store.save(set)
        let release = try #require(store.set(containing: disc2)).release
        #expect(release.isManual && release.isCustomSet && release.sharesAlbumEdits)
        #expect(!MusicBrainzRelease.manual(toc: disc2).sharesAlbumEdits)
        #expect(release.cdPositions == [1, 2, 3, 4] && release.title == "Seven Classic LPs")
        #expect(release.medium(for: disc2)?.position == 2 && release.medium(for: disc3)?.tracks.count == 3)
        #expect(release.media[0].tracks.isEmpty && release.media[0].discIDs.isEmpty)
        #expect(set.freePositions == [1, 4])

        // Disc 3 moves to position 4, then to another set.
        set.put(disc3, at: 4, namedAs: .manual(toc: disc3))
        #expect(set.discs.map(\.position) == [2, 4])
        let other = CustomSet(
            title: "Other", artist: "X", discCount: 2,
            discs: [.init(position: 1, discID: disc3.musicBrainzDiscID, tracks: [])])
        try store.save(set)
        try store.save(other)
        #expect(store.set(id: set.id)?.discs.map(\.position) == [2])
        #expect(store.set(containing: disc3)?.id == other.id)
        #expect(store.sets().map(\.id) == [other.id, set.id])
        try store.remove(disc2)
        // The set had disc 2 only, after disc 3 moved: with none left, it goes.
        #expect(store.set(containing: disc2) == nil && store.set(id: set.id) == nil && store.sets().count == 1)
    }

    /// A set whose only disc moves to another set goes; a file that does not read is not
    /// replaced by the one set being saved.
    @Test func keepsTheFileSound() throws {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        let (disc, _) = try makeDisc(trackSectors: [800, 900])
        let first = CustomSet(
            title: "First", artist: "X", discCount: 2,
            discs: [.init(position: 1, discID: disc.musicBrainzDiscID, tracks: [])])
        let second = CustomSet(
            title: "Second", artist: "X", discCount: 2,
            discs: [.init(position: 2, discID: disc.musicBrainzDiscID, tracks: [])])
        try store.save(first)
        try store.save(second)
        #expect(store.sets().map(\.id) == [second.id])

        try Data("[{\"broken\"".utf8).write(to: root.appending(path: "CustomSets.json"))
        #expect(throws: (any Error).self) { try store.save(first) }
        #expect(try String(contentsOf: root.appending(path: "CustomSets.json"), encoding: .utf8) == "[{\"broken\"")
    }

    /// A disc that MusicBrainz has, put in a set, keeps MusicBrainz's names but none of its IDs.
    @Test func takesADiscThatMusicBrainzHas() throws {
        let (toc, _) = try makeDisc(trackSectors: [800, 900])
        var release = MusicBrainzRelease.manual(toc: toc)
        release.id = "mbid"
        release.media[0].tracks[0].title = "Theme From Mr. Broadway"
        release.media[0].tracks[0].recordingID = "rec"
        release.media[0].tracks[0].artistCredit = [.init(name: "Dave Brubeck", artistID: "artist")]
        var set = CustomSet(title: "Seven Classic LPs", artist: "Dave Brubeck", discCount: 4)
        set.put(toc, at: 4, namedAs: release)
        let track = try #require(set.release.medium(for: toc)?.tracks.first)
        #expect(track.title == "Theme From Mr. Broadway" && track.recordingID == nil)
        #expect(track.artistCredit.map(\.name) == ["Dave Brubeck"] && track.artistCredit[0].artistID == nil)
    }

    /// A rip of a disc in a custom set takes the set's release, even when MusicBrainz could
    /// answer for the disc, and its discs make a set.
    @Test func ripsADiscOfACustomSet() async throws {
        let (store, storeRoot) = store()
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let (toc, _) = try makeDisc(trackSectors: [800, 900])
        var set = CustomSet(title: "Seven Classic LPs", artist: "Dave Brubeck", discCount: 4)
        set.put(toc, at: 2, namedAs: .manual(toc: toc))
        try store.save(set)
        let (result, events, _, root) = try await DiscRipTests().rip(customSets: store)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(events.contains { if case .customSet(_, 2) = $0 { true } else { false } })
        #expect(!events.contains { if case .release = $0 { true } else { false } })
        #expect(result.report.release?.id == set.id && result.report.discPosition == 2)
        #expect(result.folder.lastPathComponent == "Dave Brubeck - Seven Classic LPs (Disc 2)")
        let sets = RipSet.sets(
            in: [
                .init(
                    folder: result.folder, file: result.folder.appending(path: "disc.json"), report: result.report,
                    hasAudio: true)
            ])
        #expect(sets.map(\.releaseID) == [set.id] && sets.first?.missing == [1, 3, 4])
    }
}
