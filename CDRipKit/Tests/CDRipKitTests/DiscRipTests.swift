import Foundation
import Testing

@testable import CDRipKit

struct DiscRipTests {
    /// An offline rip of a simulated disc into a temporary folder, and the events it sent.
    /// With `hidesFirstTrack`, the first of `trackSectors` is audio before track 1.
    func rip(
        trackSectors: [Int] = [800, 900], hidesFirstTrack: Bool = false, tracks: [Int]? = nil
    ) async throws -> (DiscRipResult, [DiscRipEvent], samples: [UInt32], root: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "CDRipTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var (toc, samples) = try makeDisc(trackSectors: trackSectors)
        if hidesFirstTrack {
            toc = try TOC(audioTrackStarts: toc.audioTracks.dropFirst().map(\.startLBA), leadOutLBA: toc.leadOutLBA)
        }
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: 6)
        drive.isrcs = [1: "USRC17607839"]
        var settings = Settings()
        settings.rips = root.path
        var options = DiscRipOptions(settings: settings)
        options.offline = true
        options.tracks = tracks
        let profiles = try DriveProfileStore(url: root.appending(path: "DriveProfiles.json"))
        var rip = DiscRip(
            drive: drive, identity: DriveIdentity(vendor: "SIM", product: "DRIVE", revision: "1.0"),
            settings: settings, options: options, profiles: profiles)
        // The offset comes from the options, since an offline rip cannot look it up.
        rip.options.readOffset = 6
        final class Events { var list = [DiscRipEvent]() }
        let events = Events()
        rip.events = { events.list.append($0) }
        return (try await rip.run(), events.list, samples, root)
    }

    @Test func ripsEveryTrackIntoAFolderNamedFromTheDiscID() async throws {
        let (result, events, samples, root) = try await rip()
        defer { try? FileManager.default.removeItem(at: root) }
        let toc = try TOC(ctdbTOCString: result.report.toc)
        #expect(result.folder.lastPathComponent == "CDRip \(toc.musicBrainzDiscID)")
        #expect(result.report.tracks.map(\.number) == [1, 2])
        #expect(result.report.tracks[0].isrc == "USRC17607839")
        // The offset-corrected audio, as the WAV files hold it.
        let track1 = try WAVFile.read(result.folder.appending(path: "Track 01.wav"))
        #expect(track1 == Array(samples[0..<(800 * CDDA.samplesPerSector)]))
        for name in ["Track 02.wav", "disc.json", "Rip Report.md"] {
            #expect(FileManager.default.fileExists(atPath: result.folder.appending(path: name).path))
        }
        // The claim on the folder ends with the rip.
        #expect(!FileManager.default.fileExists(atPath: result.folder.appending(path: RipFolder.claimFile).path))

        // The steps, in order.
        let steps = events.compactMap { event -> String? in
            switch event {
            case .disc: "disc"
            case .drive(_, let offset, let source): "drive \(offset) \(source)"
            case .release(nil): "no release"
            case .folder: "folder"
            case .trackStarted(let track, let position, let count): "start \(track.number) \(position)/\(count)"
            case .trackFinished(let report, _, _): "finish \(report.number)"
            case .finished: "finished"
            default: nil
            }
        }
        #expect(
            steps == [
                "disc", "drive 6 --offset", "no release", "folder", "start 1 1/2", "finish 1", "start 2 2/2",
                "finish 2", "finished",
            ])
        #expect(events.contains { if case .reading = $0 { true } else { false } })
    }

    @Test func ripsOnlyTheChosenTracks() async throws {
        let (result, _, _, root) = try await rip(tracks: [2])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(result.report.tracks.map(\.number) == [2])
        #expect(!FileManager.default.fileExists(atPath: result.folder.appending(path: "Track 01.wav").path))
    }

    @Test func rejectsTracksThatTheDiscDoesNotHave() async throws {
        await #expect(throws: DiscRipError.noSuchTracks([3])) { _ = try await rip(tracks: [2, 3]) }
    }

    @Test func keepsTheAudioBeforeTrackOne() async throws {
        // Track 1 starts at sector 300; the audio before it is not silence.
        let (result, events, samples, root) = try await rip(trackSectors: [300, 800, 900], hidesFirstTrack: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hidden = try #require(result.report.hiddenTrack)
        #expect(hidden.sectors == 300)
        #expect(events.contains { if case .hiddenTrack = $0 { true } else { false } })
        let audio = try WAVFile.read(result.folder.appending(path: "Track 00.wav"))
        #expect(audio == Array(samples[0..<(300 * CDDA.samplesPerSector)]))
    }
}
