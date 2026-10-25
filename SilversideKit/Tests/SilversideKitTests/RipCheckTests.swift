import Foundation
import Testing

@testable import SilversideKit

struct RipCheckTests {
    /// A disc that neither database had at the rip, as with a new release: Check Again finds
    /// nothing at first, then verifies the rip once both have the disc.
    @Test func verifiesARipOnceTheDatabasesHaveTheDisc() async throws {
        let (toc, samples) = try makeDisc(trackSectors: [800, 900])
        let (ripped, _, _, root) = try await DiscRipTests().rip(web: FakeWeb())
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ripped.report.tracks.map(\.accurateRip) == [.notInDatabase, .notInDatabase])
        #expect(ripped.report.ctdb.status == .notInDatabase && !ripped.report.isVerified)
        let file = ripped.folder.appending(path: "disc.json")
        let written = try RipReport.read(from: file)

        var check = RipCheck(reportAt: file)
        check.webClient = await FakeWeb().client(in: root.appending(path: "cache"))
        let same = try await check.run()
        #expect(!same.changed && same.summary.hasPrefix("No change.") && same.after.checkedAgain != nil)

        // The rip's cache still has the 404s, so only a new request finds the disc.
        let web = DiscRipTests.web(toc: toc, samples: samples)
        check.webClient = await web.client(in: root.appending(path: "cache"))
        let result = try await check.run()
        #expect(result.changed && result.summary.hasPrefix("Now verified."))
        #expect(result.after.tracks.map(\.accurateRip) == [.accurate, .accurate])
        #expect(result.after.tracks.map(\.accurateRipConfidence) == [[0, 7], [0, 7]])
        #expect(result.after.ctdb.status == .verified)

        let saved = try RipReport.read(from: file)
        #expect(saved.isVerified && saved.checkedAgain != nil && saved.tracks.map(\.ctdbConfidence) == [5, 5])
        // The rest of the report stays as the rip wrote it.
        #expect(saved.files == written.files && saved.date == written.date && saved.drive == written.drive)
        let markdown = try String(contentsOf: ripped.folder.appending(path: "Rip Report.md"), encoding: .utf8)
        #expect(markdown.contains("Checked again in AccurateRip and CTDB"))
        #expect(RippedDisc.isVerified(try RippedDisc(folder: ripped.folder)))
    }

    /// A match is kept when a later lookup finds less, as when a database cannot be reached.
    @Test func keepsAMatchWhenTheLookupFindsLess() async throws {
        let (toc, samples) = try makeDisc(trackSectors: [800, 900])
        let (ripped, _, _, root) = try await DiscRipTests().rip(web: DiscRipTests.web(toc: toc, samples: samples))
        defer { try? FileManager.default.removeItem(at: root) }
        var check = RipCheck(reportAt: ripped.folder.appending(path: "disc.json"))
        check.webClient = await FakeWeb().client(in: root.appending(path: "other cache"))
        let result = try await check.run()
        #expect(result.after.tracks.map(\.accurateRip) == [.accurate, .accurate])
        #expect(result.after.ctdb.status == .verified && !result.changed)
    }

    /// An unverified rip keeps its WAV files after encoding: Check Again updates its report
    /// and the album's copy. Once the WAV files are gone, the album's FLAC files are checked.
    @Test func checksAnEncodedRip() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (toc, samples) = try makeDisc(trackSectors: [800, 900])
        var settings = Settings()
        settings.rips = root.appending(path: "rips").path
        var options = DiscRipOptions(settings: settings)
        options.readOffset = 6
        options.manualRelease = .manual(toc: toc)
        var rip = DiscRip(
            drive: SimulatedDrive(toc: toc, samples: samples, readOffset: 6),
            identity: DriveIdentity(vendor: "SIM", product: "DRIVE", revision: "1.0"), settings: settings,
            options: options, profiles: try DriveProfileStore(url: root.appending(path: "DriveProfiles.json")))
        rip.webClient = await FakeWeb().client(in: root.appending(path: "cache"))
        var encoder = DiscEncoder(format: .flac)
        encoder.allowsUnverified = true
        rip.encoder = encoder
        rip.library = root.appending(path: "library")
        let ripped = try await rip.run()
        #expect(ripped.encodedFiles.count == 2 && !ripped.deletedRip)
        let report = try RipReport.read(from: ripped.folder.appending(path: "disc.json"))
        let album = URL(filePath: try #require(report.encoding?.folder), directoryHint: .isDirectory)
        let albumReport = album.appending(path: "Rip Report.json")
        #expect(try !RipReport.read(from: albumReport).isVerified)

        let web = DiscRipTests.web(toc: toc, samples: samples)
        var check = RipCheck(reportAt: ripped.folder.appending(path: "disc.json"))
        check.webClient = await web.client(in: root.appending(path: "cache"))
        #expect(try await check.run().after.isVerified)
        let saved = try RipReport.read(from: albumReport)
        #expect(saved.isVerified && saved.encoding == report.encoding)
        #expect(
            try String(contentsOf: album.appending(path: "Rip Report.md"), encoding: .utf8).contains("Checked again"))

        try RippedDisc(folder: ripped.folder).deleteRipFiles()
        check = RipCheck(reportAt: albumReport)
        check.webClient = await web.client(in: root.appending(path: "cache"))
        let fromAlbum = try await check.run()
        #expect(fromAlbum.after.isVerified && !fromAlbum.changed)
    }

    @Test func needsTheRippedAudio() async throws {
        let (ripped, _, _, root) = try await DiscRipTests().rip(web: FakeWeb())
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: ripped.folder.appending(path: "Track 02.wav"))
        var check = RipCheck(reportAt: ripped.folder.appending(path: "disc.json"))
        check.webClient = await FakeWeb().client(in: root.appending(path: "cache"))
        await #expect(throws: RipCheckError.noRippedAudio(ripped.folder)) { try await check.run() }
    }
}

extension RippedDisc {
    fileprivate static func isVerified(_ disc: RippedDisc) -> Bool { disc.tracks.allSatisfy(\.isVerified) }
}
