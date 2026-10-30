import Foundation
import Testing

@testable import SilversideKit

/// A rip keeps an earlier copy of a track that AccurateRip says is accurate, and reads only
/// the other tracks: a stopped rip's tracks in its folder, or a pooled rip's.
struct KeptTracksTests {
    /// A rip of a disc of three tracks, in AccurateRip and CTDB, into `root`, after `prepare`
    /// puts files in its folder ("Silverside <disc ID>": MusicBrainz does not know the disc).
    func rip(
        root: URL, pool: [URL] = [], keeps: Bool = true,
        prepare: (_ folder: URL, _ track: (Int) -> [UInt32]) throws -> Void
    ) async throws -> (report: RipReport, folder: URL) {
        let (toc, samples) = try makeDisc(trackSectors: [800, 900, 700])
        func track(_ number: Int) -> [UInt32] {
            let sectors = toc.sectorRange(of: toc.audioTracks[number - 1])
            return Array(samples[(sectors.lowerBound * 588)..<(sectors.upperBound * 588)])
        }
        var settings = Settings()
        settings.rips = root.path
        let folder = root.appending(path: "Silverside \(toc.musicBrainzDiscID)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try prepare(folder, track)
        var options = DiscRipOptions(settings: settings)
        options.readOffset = 6
        options.pool = pool
        options.keepsAccurateTracks = keeps
        var rip = DiscRip(
            drive: SimulatedDrive(toc: toc, samples: samples, readOffset: 6),
            identity: DriveIdentity(vendor: "SIM", product: "DRIVE", revision: "1.0"), settings: settings,
            options: options, profiles: try DriveProfileStore(url: root.appending(path: "DriveProfiles.json")))
        rip.webClient = await DiscRipTests.web(toc: toc, samples: samples).client(in: root.appending(path: "cache"))
        let result = try await rip.run()
        return (result.report, result.folder)
    }

    func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A stopped rip left tracks 1 and 2, and track 2 is wrong: track 1 is kept, and tracks 2
    /// and 3 are read. CTDB checks the whole disc as usual.
    @Test func keepsAStoppedRipsAccurateTracks() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (report, folder) = try await rip(root: root) { folder, track in
            try WAVFile.write(track(1), to: folder.appending(path: "Track 01.wav"))
            try Data("old".utf8).write(to: folder.appending(path: "Track 01.suspects"))
            var wrong = track(2)
            wrong[5000] ^= 0x0101
            try WAVFile.write(wrong, to: folder.appending(path: "Track 02.wav"))
        }
        #expect(report.tracks.map(\.keptFrom) == [folder.lastPathComponent, nil, nil])
        #expect(report.tracks[0].fullReads == 0 && report.tracks[0].readSeconds == nil)
        #expect(report.tracks.allSatisfy { $0.accurateRip == .accurate })
        #expect(report.ctdb.status == .verified)
        // The kept track's checksums are recorded, and the old suspects beside it are gone.
        #expect(report.tracks[0].crc32 != nil && report.tracks[0].accurateRipChecksums != nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Track 01.suspects").path))
        #expect(report.keptText?.hasPrefix("Track 1 was not read again") == true)
        let markdown = try String(contentsOf: folder.appending(path: "Rip Report.md"), encoding: .utf8)
        #expect(markdown.contains("| kept |") && markdown.contains("Track 1 was not read again"))
    }

    /// A pooled rip's accurate copy is kept and written into this rip's folder; the pooled
    /// folder is left as it is.
    @Test func keepsAPooledRipsAccurateTrack() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appending(path: "other drive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let (report, folder) = try await rip(root: root, pool: [other]) { _, track in
            try WAVFile.write(track(3), to: other.appending(path: "Track 03.wav"))
            try Data("other".utf8).write(to: other.appending(path: "Track 03.suspects"))
        }
        #expect(report.tracks.map(\.keptFrom) == [nil, nil, "other drive"])
        #expect(
            try WAVFile.read(folder.appending(path: "Track 03.wav"))
                == WAVFile.read(other.appending(path: "Track 03.wav")))
        #expect(FileManager.default.fileExists(atPath: other.appending(path: "Track 03.suspects").path))
        #expect(report.files?.contains("Track 03.wav") == true)
    }

    /// With keeping off (Read every track again, `--read-all`), every track is read.
    @Test func readsEveryTrackWhenAsked() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (report, _) = try await rip(root: root, keeps: false) { folder, track in
            try WAVFile.write(track(1), to: folder.appending(path: "Track 01.wav"))
        }
        #expect(report.tracks.allSatisfy { $0.keptFrom == nil && $0.fullReads >= 1 })
        #expect(report.keptText == nil)
    }
}
