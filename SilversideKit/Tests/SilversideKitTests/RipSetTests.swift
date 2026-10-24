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

    static func report(_ release: MusicBrainzRelease, toc: TOC, date: Date = Date(), verified: Bool = true)
        -> RipReport
    {
        // A report with no tracks counts as verified; an unverified one has a track that is not.
        let tracks =
            verified
            ? []
            : [
                RipReport.Track(
                    number: 1, file: "Track 01.wav", startLBA: 0, sectors: 100, preEmphasis: false,
                    accurateRip: .notAccurate)
            ]
        var report = RipReport(
            date: date,
            drive: RipReport.Drive(vendor: "V", product: "P", revision: "1", readOffset: 6, offsetSource: "t"),
            secure: true, toc: toc, tracks: tracks,
            ctdb: RipReport.CTDBResult(status: verified ? .verified : .notVerified))
        report.release = release
        return report
    }

    static func rip(_ folder: URL, _ report: RipReport, hasAudio: Bool = true) -> RipSet.Rip {
        RipSet.Rip(folder: folder, file: folder.appending(path: "disc.json"), report: report, hasAudio: hasAudio)
    }

    @Test func findsTheDiscOfARelease() throws {
        let (release, tocs) = try Self.cornell()
        #expect(Self.report(release, toc: try #require(tocs[2])).discPosition == 2)
    }

    /// The newest rip of each disc counts; the summary names the discs to do, and the ones
    /// ripped but not verified or not encoded.
    @Test func groupsTheRipsOfASetAndNamesTheMissingDiscs() throws {
        let (release, tocs) = try Self.cornell()
        let folder = URL(filePath: "/rips/", directoryHint: .isDirectory)
        let old = Date(timeIntervalSince1970: 1000)
        var encoded = Self.report(release, toc: try #require(tocs[3]))
        encoded.encoding = .init(format: .flac, encoder: "t", folder: "/library/x", files: [])
        let rips = [
            Self.rip(folder.appending(path: "disc1 old"), Self.report(release, toc: try #require(tocs[1]), date: old)),
            Self.rip(
                folder.appending(path: "disc1"), Self.report(release, toc: try #require(tocs[1]), verified: false)),
            Self.rip(folder.appending(path: "disc3"), encoded),
        ]
        let sets = RipSet.sets(in: rips)
        #expect(sets.count == 1)
        let set = try #require(sets.first)
        #expect(set.releaseID == release.id && set.discCount == 3 && set.positions == [1, 2, 3])
        #expect(set.discs.keys.sorted() == [1, 3] && set.discs[1]?.folder == folder.appending(path: "disc1"))
        #expect(set.discs[1]?.stateText == "ripped, not verified" && set.discs[3]?.stateText == "verified and encoded")
        #expect(set.missing == [2] && set.unfinished == [1] && !set.isComplete)
        #expect(set.summary == "Discs 1 and 3 of 3 ripped; disc 2 still to do; disc 1 not verified")
        // A report kept in the library counts as encoded.
        var complete = set
        complete.discs[1] = .init(
            position: 1, folder: folder, file: folder, date: Date(), hasAudio: false, isVerified: true, isEncoded: true)
        complete.discs[2] = .init(
            position: 2, folder: folder, file: folder, date: Date(), hasAudio: true, isVerified: true, isEncoded: false)
        #expect(complete.summary == "Discs 1, 2, and 3 of 3 ripped; disc 2 not encoded")
        complete.discs[2]?.isEncoded = true
        #expect(complete.isComplete && complete.summary == "All 3 discs verified and encoded")
        #expect(RipSet.list([1, 2, 4]) == "1, 2, and 4")
    }

    /// A box set's DVD is not a disc to rip: the set counts the CDs only.
    @Test func countsOnlyTheCDs() throws {
        var (release, tocs) = try Self.cornell()
        release.media[1].format = "DVD-Video"
        #expect(release.cdPositions == [1, 3])
        let toc1 = try #require(tocs[1])
        let set = try #require(
            RipSet.sets(in: [Self.rip(URL(filePath: "/rips/d1"), Self.report(release, toc: toc1))]).first)

        #expect(set.discCount == 2 && set.missing == [3])
        #expect(set.summary == "Disc 1 of 2 ripped; disc 3 still to do; disc 1 not encoded")
        for format in ["CD", "HDCD", "Enhanced CD", "Copy Control CD", "Hybrid SACD (CD layer)", "DualDisc", "CD-R"] {
            release.media[1].format = format
            #expect(release.media[1].isCompactDisc, "\(format)")
        }
        for format in ["DVD", "Blu-ray", "SACD", "12\" Vinyl", "Cassette", "Digital Media"] {
            release.media[1].format = format
            #expect(!release.media[1].isCompactDisc, "\(format)")
        }
    }

    @Test func leavesOutReleasesOfOneDisc() throws {
        let (toc, _) = try makeDisc(trackSectors: [800, 900])
        let report = Self.report(MusicBrainzRelease.manual(toc: toc), toc: toc)
        #expect(RipSet.sets(in: [Self.rip(URL(filePath: "/rips/x"), report)]).isEmpty)
    }
}
