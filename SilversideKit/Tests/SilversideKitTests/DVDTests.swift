import Foundation
import Testing

@testable import SilversideKit

struct DVDTests {
    func navigation(reset: Bool = false, starts: [Int]? = nil, durations: [Int]? = nil) -> Data {
        let count = starts?.count ?? 2
        let lengths = durations ?? (1...count).map { $0 * 90_000 }
        var data = Data(repeating: 0, count: 4096)
        data.replaceSubrange(0..<12, with: "DVDAUDIO-ATS".utf8)
        func put(_ at: Int, _ value: Int, _ length: Int) {
            for i in 0..<length { data[at + i] = UInt8((value >> ((length - i - 1) * 8)) & 255) }
        }
        put(204, 1, 4)
        put(2048, 1, 2)
        put(2052, 31 + count * 32, 4)
        put(2056, 0x80, 1)
        put(2060, 16, 4)
        let row = 2064
        put(row + 2, count, 1)
        put(row + 3, count, 1)
        put(row + 4, lengths.reduce(0, +), 4)
        put(row + 10, 16, 2)
        put(row + 12, 16 + count * 20, 2)
        for i in 0..<count {
            put(row + 16 + i * 20 + 4, i + 1, 1)
            put(row + 16 + i * 20 + 6, starts?[i] ?? (i == 0 || reset ? 660 : 90_660), 4)
            put(row + 16 + i * 20 + 10, lengths[i], 4)
            put(row + 16 + count * 20 + i * 12 + 4, i * 100, 4)
            put(row + 16 + count * 20 + i * 12 + 8, i * 100 + 99, 4)
        }
        return data
    }

    @Test func navigationBoundsDurationsAndTimelines() throws {
        let p = try #require(DVDNavigation.presentations(ifo: navigation(), titleSet: 1, audioSectors: 200).first)
        #expect(p.unsupportedReason == nil)
        #expect(!p.resetsDecoder)
        #expect(try p.tracks[0].frames(at: 96_000) == 96_000)
        #expect(try p.tracks[1].frames(at: 96_000) == 192_000)
        #expect(
            try DVDNavigation.presentations(ifo: navigation(reset: true), titleSet: 1, audioSectors: 200)[0]
                .resetsDecoder)
        #expect(throws: DVDError.self) {
            try DVDNavigation.presentations(ifo: navigation(), titleSet: 1, audioSectors: 199)
        }
        for length in [0, 12, 2048, 2055, 2064, 2100, 2143] {
            #expect(throws: DVDError.self) {
                try DVDNavigation.presentations(ifo: navigation().prefix(length), titleSet: 1, audioSectors: 200)
            }
        }
        var bad = navigation()
        bad[2064 + 7] = 0
        #expect(throws: DVDError.self) { try DVDNavigation.presentations(ifo: bad, titleSet: 1, audioSectors: 200) }
        bad = navigation()
        bad[2064 + 3] = 3
        #expect(try DVDNavigation.presentations(ifo: bad, titleSet: 1, audioSectors: 200)[0].unsupportedReason != nil)
        bad = navigation()
        bad[2064 + 36 + 9] ^= 1
        #expect(try DVDNavigation.presentations(ifo: bad, titleSet: 1, audioSectors: 200)[0].unsupportedReason != nil)
    }

    @Test func selectionDoesNotGuessOrInventStereo() throws {
        var surround = try DVDNavigation.presentations(ifo: navigation(), titleSet: 1, audioSectors: 200)[0]
        surround.format = DVDAudioFormat(codec: "mlp", sampleRate: 96000, bits: 24, channels: 6, layout: "5.1")
        var stereo = surround
        stereo.title = 2
        stereo.format = DVDAudioFormat(codec: "mlp", sampleRate: 96000, bits: 24, channels: 2, layout: "stereo")
        var inventory = DVDInventory(
            source: "fixture", volume: "fixture", fingerprint: "fixture", libraryPath: "fixture",
            presentations: [surround])
        #expect(try DVDExtraction.select(inventory).map(\.id) == ["1:1"])
        #expect(throws: DVDError.self) { try DVDExtraction.select(inventory, mix: .stereo) }
        inventory.presentations.append(stereo)
        #expect(try DVDExtraction.select(inventory, mix: .both).map(\.id) == ["1:1", "1:2"])
        var extra = surround
        extra.title = 3
        inventory.presentations.append(extra)
        #expect(throws: DVDError.self) { try DVDExtraction.select(inventory) }
        #expect(try DVDExtraction.select(inventory, title: "1:3").count == 1)
        inventory.presentations[2].unsupportedReason = "unsupported fixture"
        #expect(throws: DVDError.self) { try DVDExtraction.select(inventory, title: "1:3") }
    }

    @Test func groupsContinuousTracksAcrossClockRestarts() throws {
        let starts = [98, 90_098, 97, 90_097, 100, 90_100]
        let data = navigation(starts: starts, durations: Array(repeating: 90_000, count: starts.count))
        let presentation = try #require(DVDNavigation.presentations(ifo: data, titleSet: 1, audioSectors: 600).first)
        #expect(presentation.unsupportedReason == nil)
        #expect(try presentation.decodingRuns().map { $0.tracks.map(\.number) } == [[1, 2], [3, 4], [5, 6]])
        #expect(!presentation.resetsDecoder)
        let continuous = try DVDNavigation.presentations(ifo: navigation(), titleSet: 1, audioSectors: 200)[0]
        #expect(try continuous.decodingRuns().map { $0.tracks.map(\.number) } == [[1, 2]])
        let separate = try DVDNavigation.presentations(ifo: navigation(reset: true), titleSet: 1, audioSectors: 200)[0]
        #expect(try separate.decodingRuns().map { $0.tracks.map(\.number) } == [[1], [2]])
        for unexpected in [90_097, 90_099] {
            let broken = navigation(starts: [98, unexpected], durations: [90_000, 90_000])
            #expect(
                try DVDNavigation.presentations(ifo: broken, titleSet: 1, audioSectors: 200)[0].unsupportedReason != nil
            )
        }
    }

    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SilversideDVDTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test func failuresKeepAReportAndNeverReplaceExistingOutput() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = DVDTools(
            helper: URL(fileURLWithPath: "/usr/bin/false"), ffmpeg: URL(fileURLWithPath: "/usr/bin/false"),
            ffprobe: URL(fileURLWithPath: "/usr/bin/false"))
        let output = root.appendingPathComponent("rip")
        #expect(throws: DVDError.self) {
            try DVDExtraction.rip(source: "/missing-source", output: output, tools: tools)
        }
        let reportURL = output.appendingPathComponent("dvd-rip.json")
        let original = try Data(contentsOf: reportURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DVDRipReport.self, from: original)
        #expect(report.status == "failed")
        #expect(report.retainedWork?.directory == ".work")
        #expect(report.retainedWork?.bytes == 0)
        let text = try String(contentsOf: output.appendingPathComponent("Rip Report.txt"), encoding: .utf8)
        #expect(text.contains("Retained scratch files:") && text.contains("no resume support"))
        let reference = root.appendingPathComponent("normal-directory")
        try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: false)
        func permissions(_ folder: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
            return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        }
        #expect(try permissions(output) == permissions(reference))
        #expect(try permissions(output.appendingPathComponent(".work")) & 0o077 == 0)
        #expect(throws: DVDError.self) {
            try DVDExtraction.rip(source: "/missing-source", output: output, tools: tools)
        }
        #expect(try Data(contentsOf: reportURL) == original)
        #expect(throws: DVDError.self) {
            try DVDExtraction.rip(source: root.path, output: root.appendingPathComponent("inside"), tools: tools)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("inside").path))
    }

    @Test func retainedWorkCountsHiddenFilesWithoutFollowingLinks() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent(".work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        try Data(repeating: 0, count: 4096).write(to: work.appendingPathComponent("program.aob"))
        try Data(repeating: 1, count: 13).write(to: work.appendingPathComponent(".diagnostics"))
        let outside = root.appendingPathComponent("other-data")
        try Data(repeating: 2, count: 100).write(to: outside)
        try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("link"), withDestinationURL: outside)
        #expect(DVDExtraction.retainedBytes(in: work) == 4109)
        #expect(try Data(contentsOf: outside).count == 100)
    }

    @Test func timestampsRequireEvidenceBeforeRounding() throws {
        for (rate, ticks, frames) in [(44_100, 100, 49), (88_200, 50, 49), (176_400, 25, 49), (48_000, 150, 80)] {
            var track = DVDTrack(number: 1, startPTS: 0, durationPTS: Int64(ticks), firstSector: 0, lastSector: 1)
            #expect(try track.frames(at: rate) == Int64(frames))
            track.durationPTS += 1
            #expect(throws: DVDError.self) { try track.frames(at: rate) }
        }
    }

    @Test func cancellationTerminatesChildAndRecordsCancellation() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let stop = StopToken()
        // A dedicated thread cannot be starved by the suite's concurrent blocking
        // tests occupying the global cooperative executor.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.2)
            stop.stop()
        }
        let start = Date()
        #expect(throws: CancellationError.self) {
            try DVDProcess.run(URL(fileURLWithPath: "/bin/sleep"), ["10"], in: root, stop: stop)
        }
        #expect(Date().timeIntervalSince(start) < 5)
        let tools = DVDTools(
            helper: URL(fileURLWithPath: "/usr/bin/false"), ffmpeg: URL(fileURLWithPath: "/usr/bin/false"),
            ffprobe: URL(fileURLWithPath: "/usr/bin/false"))
        let output = root.appendingPathComponent("cancelled")
        #expect(throws: CancellationError.self) {
            try DVDExtraction.rip(source: "/missing", output: output, tools: tools, stop: stop)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(
            DVDRipReport.self, from: Data(contentsOf: output.appendingPathComponent("dvd-rip.json")))
        #expect(report.status == "cancelled")
        #expect(report.retainedWork?.directory == ".work" && report.retainedWork?.bytes == 0)
    }

    @Test func packetValidationRejectsScramblingAndBadMarkers() throws {
        var bytes = Data(repeating: 0, count: 2048)
        bytes.replaceSubrange(0..<4, with: [0, 0, 1, 0xba])
        bytes.replaceSubrange(14..<28, with: [0, 0, 1, 0xbd, 0, 8, 0x80, 0x80, 5, 0x21, 0, 1, 5, 0x29])
        #expect(try DVDExtraction.firstAudioPTS(bytes) == 660)
        bytes[20] |= 0x30
        #expect(throws: DVDError.self) { try DVDExtraction.firstAudioPTS(bytes) }
        bytes[20] = 0x80
        bytes[27] &= 0xfe
        #expect(throws: DVDError.self) { try DVDExtraction.firstAudioPTS(bytes) }
        #expect(throws: DVDError.self) { try DVDExtraction.firstAudioPTS(Data()) }
    }

    /// Six distinct tones catch accidental channel loss/reordering; unequal cuts catch
    /// off-by-one boundaries. This exercises real FFmpeg when the optional tool is present.
    @Test func exactMultichannelSplitPreservesPCM() throws {
        guard let ffmpeg = FFmpeg.program() else { return }
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = DVDTools(
            helper: URL(fileURLWithPath: "/usr/bin/false"), ffmpeg: ffmpeg,
            ffprobe: ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe"))
        let stop = StopToken()
        let source = root.appendingPathComponent("fixture.flac")
        let tones = (1...6).map { "0.1*sin(2*PI*\($0 * 347)*t)" }.joined(separator: "|")
        try DVDExtraction.clean(
            DVDProcess.run(
                ffmpeg,
                DVDExtraction.common + [
                    "-f", "lavfi", "-i", "aevalsrc=\(tones):s=96000:d=3:c=5.1", "-c:a", "flac", "-sample_fmt", "s32",
                    "-bits_per_raw_sample", "24", source.path,
                ], in: root, stop: stop))
        var p = try DVDNavigation.presentations(ifo: navigation(), titleSet: 1, audioSectors: 200)[0]
        p.format = DVDAudioFormat(codec: "mlp", sampleRate: 96000, bits: 24, channels: 6, layout: "5.1")
        try DVDExtraction.split(source, p: p, tools: tools, work: root, stop: stop)
        let tracks = [root.appendingPathComponent("01.flac"), root.appendingPathComponent("02.flac")]
        for (track, file) in zip(p.tracks, tracks) {
            try DVDExtraction.verifyFormat(
                file, frames: track.frames(at: 96000), format: p.format!, tools: tools, work: root, stop: stop)
        }
        #expect(
            try DVDExtraction.pcmHash(source, bits: 24, tools: tools, work: root, stop: stop)
                == DVDExtraction.joinedHash(tracks, bits: 24, tools: tools, work: root, stop: stop))
        #expect(throws: DVDError.self) {
            try DVDExtraction.verifyFormat(
                tracks[0], frames: 96001, format: p.format!, tools: tools, work: root, stop: stop)
        }
    }
}
