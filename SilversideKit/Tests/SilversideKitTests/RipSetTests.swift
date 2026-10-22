import Foundation
import Testing

@testable import SilversideKit

struct RipSetTests {
    /// *Cornell 5/8/77* from the fixtures: three discs. The TOC of each disc comes from the
    /// fixture's offsets, so the disc IDs match the release's media.
    static func cornell() throws -> (release: MusicBrainzRelease, tocs: [Int: TOC]) {
        let data = try MusicBrainzTests().fixture("cornell-1977-disc1")
        let release = try #require(MusicBrainzClient.lookup(fromJSON: data).releases.first)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let media = try #require((object["releases"] as? [[String: Any]])?.first?["media"] as? [[String: Any]])
        var tocs = [Int: TOC]()
        for medium in media {
            let disc = try #require((medium["discs"] as? [[String: Any]])?.first)
            let offsets = try #require(disc["offsets"] as? [Int])
            let sectors = try #require(disc["sectors"] as? Int)
            tocs[try #require(medium["position"] as? Int)] = try TOC(
                audioTrackStarts: offsets.map { $0 - CDDA.leadInSectors }, leadOutLBA: sectors - CDDA.leadInSectors)
        }
        return (release, tocs)
    }

    static func report(_ release: MusicBrainzRelease, toc: TOC, date: Date = Date()) -> RipReport {
        var report = RipReport(
            date: date,
            drive: RipReport.Drive(vendor: "V", product: "P", revision: "1", readOffset: 6, offsetSource: "t"),
            secure: true, toc: toc, tracks: [], ctdb: RipReport.CTDBResult(status: .notChecked))
        report.release = release
        return report
    }

    @Test func findsTheDiscOfARelease() throws {
        let (release, tocs) = try Self.cornell()
        let report = Self.report(release, toc: try #require(tocs[2]))
        #expect(report.discPosition == 2)
        #expect(report.medium?.tracks.count == 4)
    }

    @Test func groupsTheRipsOfASetAndNamesTheMissingDiscs() throws {
        let (release, tocs) = try Self.cornell()
        let folder = URL(filePath: "/rips/", directoryHint: .isDirectory)
        let old = Date(timeIntervalSince1970: 1000)
        let rips: [(folder: URL, report: RipReport)] = [
            (folder.appending(path: "disc1 old"), Self.report(release, toc: try #require(tocs[1]), date: old)),
            (folder.appending(path: "disc1"), Self.report(release, toc: try #require(tocs[1]))),
            (folder.appending(path: "disc3"), Self.report(release, toc: try #require(tocs[3]))),
        ]
        let sets = RipSet.sets(in: rips)
        #expect(sets.count == 1)
        let set = try #require(sets.first)
        #expect(set.releaseID == release.id && set.discCount == 3)
        #expect(set.discs == [1: folder.appending(path: "disc1"), 3: folder.appending(path: "disc3")])
        #expect(set.missing == [2])
        #expect(!set.isComplete)
        #expect(set.summary == "Discs 1 and 3 of 3 ripped; disc 2 still to do")
        var complete = set
        complete.discs[2] = folder.appending(path: "disc2")
        #expect(complete.summary == "All 3 discs ripped")
        #expect(RipSet.list([1, 2, 4]) == "1, 2, and 4")
    }

    @Test func leavesOutReleasesOfOneDisc() throws {
        let (toc, _) = try makeDisc(trackSectors: [800, 900])
        let report = Self.report(MusicBrainzRelease.manual(toc: toc), toc: toc)
        #expect(RipSet.sets(in: [(URL(filePath: "/rips/x"), report)]).isEmpty)
    }
}
