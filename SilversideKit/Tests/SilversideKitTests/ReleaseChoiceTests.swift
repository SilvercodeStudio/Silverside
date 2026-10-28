import Foundation
import Testing

@testable import SilversideKit

struct ReleaseChoiceTests {
    func release(
        _ id: String, discIDs: [[String]], barcode: String? = nil, status: String? = "Official"
    ) -> MusicBrainzRelease {
        MusicBrainzRelease(
            id: id, title: id, artistCredit: [.init(name: "Grateful Dead")], date: nil, country: nil, status: status,
            barcode: barcode, disambiguation: nil, labels: [], releaseGroup: nil,
            media: discIDs.enumerated().map {
                .init(position: $0.offset + 1, format: "CD", title: nil, discIDs: $0.element, tracks: [])
            },
            hasFrontCover: false)
    }

    /// The 3-disc release comes before the 17-disc box set that holds the same discs.
    @Test func prefersAReleaseToABoxSetThatHoldsIt() {
        let box = release("box", discIDs: (1...17).map { ["d\($0)"] })
        let standalone = release("standalone", discIDs: [["d1"], ["d2"], ["d3"]])
        #expect(ReleaseRanking.ranked([box, standalone], discID: "d1").map(\.id) == ["standalone", "box"])
    }

    @Test func prefersTheBarcodeOfTheMCN() {
        let other = release("other", discIDs: [["d1"]], barcode: "081227932512")
        let matching = release("matching", discIDs: [["d1"], ["d2"]], barcode: "603497846168")
        let ranked = ReleaseRanking.ranked([other, matching], discID: "d1", mcn: "0603497846168")
        #expect(ranked.map(\.id) == ["matching", "other"])
    }

    @Test func prefersAnExactMatchAndAnOfficialRelease() {
        let fuzzy = release("fuzzy", discIDs: [["x"]])
        let bootleg = release("bootleg", discIDs: [["d1"]], status: "Bootleg")
        let official = release("official", discIDs: [["d1"]])
        #expect(
            ReleaseRanking.ranked([fuzzy, bootleg, official], discID: "d1").map(\.id) == [
                "official", "bootleg", "fuzzy",
            ])
    }

    @Test func putsTheUsersChoiceFirst() {
        let box = release("box", discIDs: (1...17).map { ["d\($0)"] })
        let standalone = release("standalone", discIDs: [["d1"], ["d2"], ["d3"]])
        let ranked = ReleaseRanking.ranked([standalone, box], discID: "d2", chosen: ["box"])
        #expect(ranked.map(\.id) == ["box", "standalone"])
    }

    @Test func asksOnlyWhenTheChoiceMatters() {
        let box = release("box", discIDs: (1...17).map { ["d\($0)"] })
        let standalone = release("standalone", discIDs: [["d1"], ["d2"], ["d3"]])
        var europe = release("standalone", discIDs: [["d1"], ["d2"], ["d3"]], barcode: "081227942557")
        europe.id = "europe"
        // A show and the box set that holds it.
        #expect(ReleaseRanking.isAmbiguous([standalone, box]))
        #expect(!ReleaseRanking.isAmbiguous([standalone, box], chosen: ["standalone"]))
        // Two editions of the same release.
        #expect(!ReleaseRanking.isAmbiguous([standalone, europe, box]))
        // Only the first has the disc's barcode.
        var matching = standalone
        matching.barcode = "0603497846168"
        #expect(!ReleaseRanking.isAmbiguous([matching, box], mcn: "0603497846168"))
        #expect(!ReleaseRanking.isAmbiguous([standalone]))
    }

    @Test func matchesAUPCWithAnEAN() {
        #expect(ReleaseRanking.matches(barcode: "081227932512", mcn: "0081227932512"))
        #expect(!ReleaseRanking.matches(barcode: "", mcn: "0000000000000"))
        #expect(!ReleaseRanking.matches(barcode: nil, mcn: "0081227932512"))
    }

    /// A choice for one disc of a set is the choice for the others.
    @Test func remembersAChoiceForEveryDiscOfTheRelease() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ReleaseChoices-\(UUID()).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(filePath: url.path + ".lock"))
        }
        let store = ReleaseChoiceStore(url: url)
        try store.remember(release("standalone", discIDs: [["d1"], ["d2", "d2b"], ["d3"]]))
        #expect(store.choices(forDiscID: "d2b") == ["standalone"])
        try store.remember(release("box", discIDs: [["d1"], ["d9"]]))
        #expect(store.choices(forDiscID: "d1") == ["box"] && store.choices(forDiscID: "d3") == ["standalone"])
        #expect(store.choices(forDiscID: "none").isEmpty)
    }

    /// A release chosen for another disc comes first for a disc MusicBrainz lists by its
    /// lengths only, and the choice is not put to the user again.
    @Test func prefersTheReleaseChosenForAnotherDiscOfTheSet() {
        let box = release("box", discIDs: [["a"], ["b"], ["c"]])
        let single = release("single", discIDs: [["x"]])
        let ranked = ReleaseRanking.ranked([single, box], discID: "unknown", chosenForOtherDiscs: ["box"])
        #expect(ranked.map(\.id) == ["box", "single"])
        #expect(!ReleaseRanking.isAmbiguous(ranked, chosenForOtherDiscs: ["box"]))
        #expect(ReleaseRanking.ranked([single, box], discID: "unknown").map(\.id) == ["single", "box"])
    }

    /// *Vegas 96*: disc 3's ID is on the 3-disc edition only, and the set was ripped as the
    /// 4-disc edition, whose disc 3 has no disc ID. Disc 2's ID is on a 1988 show by mistake.
    @Test func findsTheReleaseOfEarlierRipsThatTheLookupMissed() throws {
        // Disc 3, as MusicBrainz has it (offsets less the 150-sector lead-in).
        let toc = try TOC(
            audioTrackStarts: [0, 18266, 30537, 50178, 60514, 69177, 89305, 128888, 159843], leadOutLBA: 172388)
        let lengths = toc.audioTracks.map { toc.sectorRange(of: $0).count * 1000 / CDDA.sectorsPerSecond }
        func medium(_ position: Int, lengths: [Int?], discIDs: [String] = []) -> MusicBrainzRelease.Medium {
            .init(
                position: position, format: "CD", title: nil, discIDs: discIDs,
                tracks: lengths.enumerated().map {
                    .init(
                        position: $0.offset + 1, number: String($0.offset + 1), title: "", length: $0.element,
                        artistCredit: [], recordingID: nil)
                })
        }
        func made(_ id: String, media: [MusicBrainzRelease.Medium]) -> MusicBrainzRelease {
            var result = release(id, discIDs: [])
            result.media = media
            return result
        }
        let otherDisc = lengths.map { $0 + 60_000 }
        let three = made(
            "three",
            media: [
                medium(1, lengths: otherDisc), medium(2, lengths: [1, 2]),
                medium(3, lengths: lengths, discIDs: [toc.musicBrainzDiscID]),
            ])
        // Whole seconds, as people type them: still the same disc.
        let rounded = lengths.map { $0 / 1000 * 1000 }
        let four = made(
            "four",
            media: [
                medium(1, lengths: otherDisc, discIDs: ["d1"]), medium(2, lengths: [1, 2]),
                medium(3, lengths: rounded), medium(4, lengths: [1]),
            ])
        let longer = made("longer", media: [medium(1, lengths: lengths.map { $0 + 5000 })])
        let unknown = made("unknown", media: [medium(1, lengths: lengths.map { _ in nil })])

        let match = ReleaseRanking.earlierRelease(fitting: toc, found: [three], earlier: [longer, unknown, four])
        #expect(match?.release.id == "four" && match?.medium.position == 3)
        // Found by the lookup, it needs no note: the remembered choice ranks it first.
        #expect(ReleaseRanking.earlierRelease(fitting: toc, found: [three, four], earlier: [four]) == nil)
        #expect(ReleaseRanking.earlierRelease(fitting: toc, found: [three], earlier: [three, longer]) == nil)
    }
}
