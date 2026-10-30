import Foundation
import Testing

@testable import SilversideKit

struct SilentTracksTests {
    /// A verified rip of four tracks of a second each, and the library beside it: tracks 2 and 3
    /// are digital silence, as the tracks before *Broken*'s hidden songs are.
    func makeRip(silent: Set<Int> = [2, 3]) throws -> (folder: URL, library: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        let folder = root.appending(path: "rip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sectors = 75
        let toc = try TOC(audioTrackStarts: (0..<4).map { $0 * sectors }, leadOutLBA: 4 * sectors)
        var tracks = [RipReport.Track]()
        for number in 1...4 {
            let audio =
                silent.contains(number)
                ? [UInt32](repeating: 0, count: sectors * 588)
                : PreEmphasisTests.sine(Double(number) * 220, frames: sectors * 588)
            try WAVFile.write(audio, to: folder.appending(path: "Track 0\(number).wav"))
            var track = RipReport.Track(
                number: number, file: "Track 0\(number).wav", startLBA: (number - 1) * sectors, sectors: sectors,
                preEmphasis: false, accurateRip: silent.contains(number) ? .noChecksum : .accurate)
            track.recordChecksums(of: audio, isFirstTrack: number == 1, isLastTrack: number == 4)
            tracks.append(track)
        }
        var report = RipReport(
            drive: .init(vendor: "V", product: "P", revision: "1", readOffset: 6, offsetSource: "test"),
            secure: true, toc: toc, tracks: tracks, ctdb: .init(status: .verified))
        report.release = MusicBrainzRelease(
            id: "broken", title: "Broken", artistCredit: [.init(name: "Nine Inch Nails")],
            date: "1992-09-22", country: "US", status: "Official", barcode: nil, disambiguation: nil, labels: [],
            releaseGroup: nil,
            media: [
                .init(
                    position: 1, format: "CD", title: nil, discIDs: [],
                    tracks: (1...4).map {
                        .init(
                            position: $0, number: String($0), title: silent.contains($0) ? "[silence]" : "Song \($0)",
                            length: 1000, artistCredit: [.init(name: "Nine Inch Nails")], recordingID: nil)
                    })
            ], hasFrontCover: false)
        try report.write(to: folder.appending(path: "disc.json"))
        return (folder, root.appending(path: "library"))
    }

    /// The report knows a silent track by its CRC-32 that skips silent samples: nothing is left.
    @Test func findsTheSilentTracks() throws {
        let (folder, _) = try makeRip()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let report = try RipReport.read(from: folder.appending(path: "disc.json"))
        #expect(report.silentTracks == [2, 3])
        #expect(report.silentTracksText == "Tracks 2-3 are digital silence (2 of 4 tracks, 0:02 in all).")
        // A disc of nothing but silence keeps its tracks: there would be nothing left.
        let (allSilent, _) = try makeRip(silent: [1, 2, 3, 4])
        defer { try? FileManager.default.removeItem(at: allSilent.deletingLastPathComponent()) }
        #expect(try RipReport.read(from: allSilent.appending(path: "disc.json")).silentTracks.isEmpty)
    }

    /// Left out, the silent tracks get no file and no line in the album's CUE sheet; the other
    /// tracks keep the disc's numbers, and the disc image keeps every track.
    @Test func leavesOutTheSilentTracks() throws {
        let (folder, library) = try makeRip()
        let root = folder.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let disc = try RippedDisc(folder: folder)
        var encoder = DiscEncoder(format: .flac)
        encoder.leavesOutSilentTracks = true
        encoder.images = root.appending(path: "images")
        let heard = Heard()
        encoder.tracksLeftOut = { heard.numbers = $0 }
        let (files, record) = try encoder.encodeWithRecord(disc, into: library)
        #expect(heard.numbers == [2, 3])
        #expect(record?.silentTracksLeftOut == [2, 3])
        #expect(record?.files.map(\.track) == [1, 4])
        #expect(try FLACTags.read(files[1]).contains { $0.key == "TRACKNUMBER" && $0.value == "4" })
        let album = files[0].deletingLastPathComponent()
        let cue = try FileManager.default.contentsOfDirectory(atPath: album.path).first { $0.hasSuffix(".cue") }
        let sheet = try String(contentsOf: album.appending(path: try #require(cue)), encoding: .utf8)
        #expect(sheet.contains("TRACK 04 AUDIO") && !sheet.contains("TRACK 02") && !sheet.contains("TRACK 03"))
        // The image is the whole disc.
        let image = URL(filePath: try #require(record?.image))
        let ripped = try disc.tracks.flatMap { try disc.audio(of: $0) }
        #expect(try AudioEncoder.decode(image) == ripped)
        let imageSheet = try #require(try FLACTags.read(image).first { $0.key == "CUESHEET" }?.value)
        #expect((1...4).allSatisfy { imageSheet.contains(String(format: "TRACK %02d AUDIO", $0)) })
    }

    /// Kept, they are files like any track. An album whose silent tracks were left out can be
    /// encoded again with them: their audio is zeros.
    @Test func keepsTheSilentTracks() throws {
        let (folder, library) = try makeRip()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        var encoder = DiscEncoder(format: .flac)
        encoder.leavesOutSilentTracks = true
        let files = try encoder.encode(try RippedDisc(folder: folder), into: library)
        #expect(files.count == 2)
        let album = try RippedDisc(
            albumReportAt: files[0].deletingLastPathComponent().appending(path: "Rip Report.json"))
        #expect(album.tracks.map(\.number) == [1, 2, 3, 4])
        encoder.leavesOutSilentTracks = false
        encoder.overwrites = true
        let (again, record) = try encoder.encodeWithRecord(album, into: library)
        #expect(record?.silentTracksLeftOut == nil)
        #expect(again.count == 4)
        #expect(try AudioEncoder.decode(again[1]).allSatisfy { $0 == 0 })
        #expect(try AudioEncoder.decode(again[3]) == WAVFile.read(folder.appending(path: "Track 04.wav")))
    }
}

/// What a closure heard, for a test.
private final class Heard: @unchecked Sendable {
    var numbers: [Int] = []
}

extension SilentTracksTests {
    /// A rip reads and verifies every track, then asks before encoding whether to leave out the
    /// silent one; the encoding hears the answer, and the rip's WAV files go as for a whole album.
    @Test(arguments: [true, false])
    func asksAfterTheRip(leavesOut: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var (toc, samples) = try makeDisc(trackSectors: [800, 500, 900])
        let silence = (800 * CDDA.samplesPerSector)..<(1300 * CDDA.samplesPerSector)
        samples.replaceSubrange(silence, with: repeatElement(0, count: silence.count))
        var settings = Settings()
        settings.rips = root.appending(path: "rips").path
        var options = DiscRipOptions(settings: settings)
        options.readOffset = 6
        options.manualRelease = .manual(toc: toc)
        options.silentTracks = .ask
        var rip = DiscRip(
            drive: SimulatedDrive(toc: toc, samples: samples, readOffset: 6),
            identity: DriveIdentity(vendor: "SIM", product: "DRIVE", revision: "1.0"), settings: settings,
            options: options, profiles: try DriveProfileStore(url: root.appending(path: "DriveProfiles.json")))
        rip.webClient = await DiscRipTests.web(toc: toc, samples: samples).client(in: root.appending(path: "cache"))
        rip.encoder = DiscEncoder(format: .flac)
        rip.library = root.appending(path: "library")
        let asked = DiscRipEvents()
        rip.chooseSilentTracks = { report in
            #expect(report.silentTracks == [2])
            asked.append(.ripDeleted)
            return leavesOut
        }
        let result = try await rip.run()
        #expect(asked.list.count == 1)
        #expect(result.report.tracks.count == 3 && result.report.isVerified)
        #expect(result.encodedFiles.count == (leavesOut ? 2 : 3))
        #expect(result.deletedRip)
    }
}
