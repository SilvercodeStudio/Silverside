import Foundation
import Testing

@testable import SilversideKit

/// A rip keeps an earlier copy of a track that AccurateRip says is accurate, and reads only
/// the other tracks: a stopped rip's tracks in its folder, or a pooled rip's.
struct KeptTracksTests {
    /// A disc of three tracks, in AccurateRip and CTDB.
    func disc() throws -> (toc: TOC, samples: [UInt32]) { try makeDisc(trackSectors: [800, 900, 700]) }

    func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A rip of the disc into the rips folder in `root` ("Silverside <disc ID>": MusicBrainz
    /// does not know the disc), by a drive at `readOffset`. `stopsAfter` stops it after that
    /// track, as the Stop button does; the rip then gives nil.
    func rip(
        root: URL, pool: [URL] = [], keeps: Bool = true, readOffset: Int = 6, stopsAfter: Int? = nil,
        drive configure: @escaping (SimulatedDrive) -> Void = { _ in }
    ) async throws -> (report: RipReport, folder: URL)? {
        let (toc, samples) = try disc()
        var settings = Settings()
        settings.rips = root.path
        var options = DiscRipOptions(settings: settings)
        options.readOffset = readOffset
        options.pool = pool
        options.keepsAccurateTracks = keeps
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: readOffset)
        configure(drive)
        var rip = DiscRip(
            drive: drive, identity: DriveIdentity(vendor: "SIM", product: "DRIVE", revision: "1.0"),
            settings: settings, options: options,
            profiles: try DriveProfileStore(url: root.appending(path: "DriveProfiles.json")))
        rip.webClient = await DiscRipTests.web(toc: toc, samples: samples).client(in: root.appending(path: "cache"))
        let stop = rip.stop
        rip.events = { event in
            if case .trackFinished(let report, _, _) = event, report.number == stopsAfter { stop.stop() }
        }
        do {
            let result = try await rip.run()
            return (result.report, result.folder)
        } catch is CancellationError {
            return nil
        }
    }

    /// A finished rip of the disc's `tracks` in `folder`, by a drive at `readOffset`: their
    /// WAV files, with the samples that drive could not read at the audio's end as silence,
    /// and a report that describes them.
    func writeRip(of tracks: [Int], in folder: URL, readOffset: Int) throws {
        let (toc, samples) = try disc()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let padded = DiscRip.paddedEdges(of: toc, readOffset: readOffset, tracks: Set(tracks))
        var reports = [RipReport.Track]()
        for number in tracks {
            let track = toc.audioTracks[number - 1]
            let range = toc.sectorRange(of: track)
            var audio = Array(samples[(range.lowerBound * 588)..<(range.upperBound * 588)])
            for edge in padded where edge.track == number && edge.atEnd {
                audio.replaceSubrange((audio.count - edge.samples)..., with: repeatElement(0, count: edge.samples))
            }
            let file = String(format: "Track %02d.wav", number)
            try WAVFile.write(audio, to: folder.appending(path: file))
            var report = RipReport.Track(
                number: number, file: file, startLBA: range.lowerBound, sectors: range.count, preEmphasis: false,
                accurateRip: .accurate)
            report.recordChecksums(of: audio, isFirstTrack: number == 1, isLastTrack: number == toc.audioTracks.count)
            reports.append(report)
        }
        var report = RipReport(
            drive: .init(
                vendor: "OTHER", product: "DRIVE", revision: "1", readOffset: readOffset, offsetSource: "test"),
            secure: true, toc: toc, tracks: reports, ctdb: .init(status: .notChecked))
        report.paddedEdges = padded.isEmpty ? nil : padded
        try report.write(to: folder.appending(path: "disc.json"))
    }

    /// A stopped rip keeps a report of its finished tracks beside them. The next rip keeps
    /// track 1, with the pre-emphasis and the index point that only its Q subchannel gave, and
    /// reads track 2, which changed since, and track 3. CTDB checks the whole disc as usual.
    @Test func keepsAStoppedRipsAccurateTracks() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configure: (SimulatedDrive) -> Void = { drive in
            drive.qControl = [1: 0x1]
            drive.indexes = [1: [300]]
        }
        let stopped = try await rip(root: root, stopsAfter: 2, drive: configure)
        #expect(stopped == nil)
        let folder = root.appending(path: "Silverside \(try disc().toc.musicBrainzDiscID)")
        let progress = folder.appending(path: RipPool.progressFile)
        #expect(try RipReport.read(from: progress).tracks.map(\.number) == [1, 2])
        var changed = try WAVFile.read(folder.appending(path: "Track 02.wav"))
        changed[5000] ^= 0x0101
        try WAVFile.write(changed, to: folder.appending(path: "Track 02.wav"))
        try Data("old".utf8).write(to: folder.appending(path: "Track 01.suspects"))

        let (report, _) = try #require(await rip(root: root, drive: configure))
        #expect(report.tracks.map(\.keptFrom) == [folder.lastPathComponent, nil, nil])
        #expect(report.tracks[0].preEmphasis && report.tracks[0].indexes == [.init(number: 2, sectors: 300)])
        #expect(report.tracks[0].fullReads == 0 && report.tracks[0].readSeconds == nil)
        #expect(report.tracks.allSatisfy { $0.accurateRip == .accurate })
        #expect(report.ctdb.status == .verified)
        // The kept track's checksums are recorded; the old suspects beside it, and the progress, are gone.
        #expect(report.tracks[0].crc32 != nil && report.tracks[0].accurateRipChecksums != nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Track 01.suspects").path))
        #expect(!FileManager.default.fileExists(atPath: progress.path))
        #expect(report.keptText?.hasPrefix("Track 1 was not read again") == true)
        let markdown = try String(contentsOf: folder.appending(path: "Rip Report.md"), encoding: .utf8)
        #expect(markdown.contains("| kept |") && markdown.contains("Track 1 was not read again"))
    }

    /// Track files that no report describes are read again: a read gives what only the disc
    /// has, such as the Q subchannel's control bits and index points.
    @Test func readsTracksThatNoReportDescribes() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appending(path: "other drive", directoryHint: .isDirectory)
        try writeRip(of: [1, 2, 3], in: other, readOffset: 6)
        try FileManager.default.removeItem(at: other.appending(path: "disc.json"))
        let (report, _) = try #require(await rip(root: root, pool: [other]))
        #expect(report.tracks.allSatisfy { $0.keptFrom == nil })
    }

    /// A pooled rip's accurate copy is kept and written into this rip's folder; the pooled
    /// folder is left as it is.
    @Test func keepsAPooledRipsAccurateTrack() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appending(path: "other drive", directoryHint: .isDirectory)
        try writeRip(of: [3], in: other, readOffset: 6)
        try Data("other".utf8).write(to: other.appending(path: "Track 03.suspects"))
        let (report, folder) = try #require(await rip(root: root, pool: [other]))
        #expect(report.tracks.map(\.keptFrom) == [nil, nil, "other drive"])
        #expect(
            try WAVFile.read(folder.appending(path: "Track 03.wav"))
                == WAVFile.read(other.appending(path: "Track 03.wav")))
        #expect(FileManager.default.fileExists(atPath: other.appending(path: "Track 03.suspects").path))
        #expect(report.files?.contains("Track 03.wav") == true)
    }

    /// A copy whose drive left more of the audio's end as silence (+103) than this drive does
    /// (+6) is read again, so the 97 samples between come from the disc. One that left less
    /// is kept, and the report gives its padding, not this drive's.
    @Test(arguments: [(103, 6, false), (6, 103, true)])
    func keepsACopyOnlyIfItsDriveReadAsMuchOfTheEdges(earlier: Int, now: Int, kept: Bool) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appending(path: "other drive", directoryHint: .isDirectory)
        try writeRip(of: [3], in: other, readOffset: earlier)
        let (report, folder) = try #require(await rip(root: root, pool: [other], readOffset: now))
        #expect((report.tracks[2].keptFrom != nil) == kept)
        let audio = try WAVFile.read(folder.appending(path: "Track 03.wav"))
        let silence = audio.reversed().prefix { $0 == 0 }.count
        #expect(silence == min(earlier, now))
        #expect(report.paddedEdges?.first { $0.track == 3 }?.samples == silence)
    }

    /// With keeping off (Read every track again, `--read-all`), every track is read.
    @Test func readsEveryTrackWhenAsked() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appending(path: "other drive", directoryHint: .isDirectory)
        try writeRip(of: [1, 2, 3], in: other, readOffset: 6)
        let (report, _) = try #require(await rip(root: root, pool: [other], keeps: false))
        #expect(report.tracks.allSatisfy { $0.keptFrom == nil && $0.fullReads >= 1 })
        #expect(report.keptText == nil)
    }
}
