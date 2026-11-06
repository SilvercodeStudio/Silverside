import Foundation
import Testing

@testable import SilversideKit

struct DVDRunFormatTests {
    @Test func roundingRequiresIndependent44100Run() throws {
        let durations: [Int64] = [5_792_000, 5_750_204, 5_788_979, 5_704_897, 5_796_571, 5_816_081, 5_787_836]
        let expected: [Int64] = [2_838_080, 2_817_600, 2_836_600, 2_795_400, 2_840_320, 2_849_880, 2_836_040]
        for (duration, count) in zip(durations, expected) {
            let track = DVDTrack(number: 1, startPTS: 666, durationPTS: duration, firstSector: 0, lastSector: 1)
            #expect(try DVDDecodeRun(tracks: [track]).frameCounts(at: 44100) == [count])
        }
        var track = DVDTrack(number: 1, startPTS: 666, durationPTS: 5_750_204, firstSector: 0, lastSector: 1)
        #expect(throws: DVDError.self) { try DVDDecodeRun(tracks: [track, track]).frameCounts(at: 44100) }
        for rate in [48000, 88200, 96000, 176400, 192000] {
            #expect(throws: DVDError.self) { try DVDDecodeRun(tracks: [track]).frameCounts(at: rate) }
        }
        for duration in [Int64.max, 0, -1, 1] {
            track.durationPTS = duration
            #expect(throws: DVDError.self) { try DVDDecodeRun(tracks: [track]).frameCounts(at: 44100) }
        }
    }

    @Test func formatsMayChangeOnlyAtRestartsAndSelectionRemainsUnambiguous() throws {
        let five = DVDAudioFormat(codec: "mlp", sampleRate: 48000, bits: 16, channels: 5, layout: "5.0")
        let six = DVDAudioFormat(codec: "mlp", sampleRate: 96000, bits: 24, channels: 6, layout: "5.1")
        var program = try DVDNavigation.presentations(
            ifo: DVDTests().navigation(reset: true), titleSet: 1, audioSectors: 200)[0]
        program.trackFormats = [.init(number: 1, format: five), .init(number: 2, format: six)]
        program.classifyFormats()
        #expect(program.format == nil && program.unsupportedReason == nil)
        var inventory = DVDInventory(
            source: "fixture", volume: "", fingerprint: "", libraryPath: "", presentations: [program])
        #expect(try DVDExtraction.select(inventory, mix: .surround).map(\.id) == ["1:1"])
        var stereo = five
        stereo.channels = 2
        stereo.layout = "stereo"
        program.trackFormats?[0].format = stereo
        program.classifyFormats()
        inventory.presentations = [program]
        #expect(try DVDExtraction.select(inventory, title: "1:1").count == 1)
        #expect(throws: DVDError.self) { try DVDExtraction.select(inventory) }
        program.tracks[1].startPTS = program.tracks[0].startPTS + program.tracks[0].durationPTS
        program.classifyFormats()
        #expect(program.unsupportedReason?.contains("continuous run") == true)
        inventory.presentations = [program]
        #expect(throws: DVDError.self) { try DVDExtraction.select(inventory, title: "1:1") }
    }

    @Test func mixedNativeRunsMatchIndependentDecodes() throws {
        guard let ffmpeg = FFmpeg.program() else { return }
        let root = try DVDTests().temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = DVDTools(
            helper: URL(fileURLWithPath: "/usr/bin/false"), ffmpeg: ffmpeg,
            ffprobe: ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe"))
        let stop = StopToken()
        let formats = [
            DVDAudioFormat(codec: "mlp", sampleRate: 44100, bits: 24, channels: 2, layout: "stereo"),
            DVDAudioFormat(codec: "mlp", sampleRate: 48000, bits: 16, channels: 5, layout: "5.0"),
            DVDAudioFormat(codec: "mlp", sampleRate: 96000, bits: 24, channels: 6, layout: "5.1"),
        ]
        let counts = [11200, 12000, 24000]
        var data = Data()
        var tracks = [DVDTrack]()
        var hashes = [String]()
        for (index, format) in formats.enumerated() {
            let elementary = root.appendingPathComponent("original-\(index).mlp")
            // Different signals in every channel expose permutations and unwanted LFE insertion.
            let signals = (0..<format.channels).map { "0.1*sin(2*PI*\(347 + $0 * 101)*t)" }.joined(separator: "|")
            try DVDExtraction.clean(
                DVDProcess.run(
                    ffmpeg,
                    DVDExtraction.common + [
                        "-f", "lavfi", "-i", "aevalsrc=\(signals):s=\(format.sampleRate):d=0.3:c=\(format.layout)",
                        "-af", "atrim=end_sample=\(counts[index])", "-sample_fmt", format.bits == 16 ? "s16p" : "s32p",
                        "-c:a", "mlp", "-strict", "experimental", "-f", "mlp", elementary.path,
                    ], in: root, stop: stop))
            let packetData = try DVDRunTests().packets(
                Data(contentsOf: elementary), startPTS: 660, rate: format.sampleRate)
            let firstSector = data.count / 2048
            data.append(packetData)
            tracks.append(
                .init(
                    number: index + 1, startPTS: 660,
                    durationPTS: Int64(counts[index] * 90000 / format.sampleRate),
                    firstSector: firstSector, lastSector: data.count / 2048 - 1))
            let reference = try DVDProcess.run(
                ffmpeg,
                DVDExtraction.common + [
                    "-f", "mlp", "-i", elementary.path, "-c:a", DVDExtraction.pcmCodec(format.bits),
                    "-f", "hash", "-hash", "sha256", "pipe:1",
                ], in: root, stop: stop)
            try DVDExtraction.clean(reference)
            hashes.append(try DVDExtraction.hashValue(reference.output))
        }
        let source = root.appendingPathComponent("source.aob")
        try data.write(to: source)
        var program = DVDPresentation(
            titleSet: 1, title: 1, indexByte: 0x80,
            durationPTS: tracks.reduce(0) { $0 + $1.durationPTS }, tracks: tracks)
        program.trackFormats = zip(tracks, formats).map { .init(number: $0.number, format: $1) }
        program.classifyFormats()
        #expect(program.unsupportedReason == nil && program.format == nil)
        try DVDExtraction.validatePackets(source, presentation: program)
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        for (index, run) in try program.decodingRuns().enumerated() {
            let decoded = try DVDExtraction.decodeRun(
                run, of: program, source: source,
                tools: tools, work: work, stop: stop, progress: { _ in })
            #expect(decoded.run.frames == Int64(counts[index]))
            #expect(decoded.run.format == formats[index])
            #expect(decoded.run.pcmSHA256 == hashes[index])
            #expect(decoded.run.roundedDuration == (index == 0))
            #expect(decoded.tracks.first?.format == formats[index])
        }
        // Rounded navigation is only a candidate: a one-sample mismatch fails,
        // even with a perfectly valid MLP stream and matching PCM round trip.
        var wrong = program
        wrong.tracks[0].durationPTS += 2
        let rejected = root.appendingPathComponent("rejected")
        try FileManager.default.createDirectory(at: rejected, withIntermediateDirectories: false)
        #expect(throws: DVDError.self) {
            try DVDExtraction.decodeRun(
                .init(tracks: [wrong.tracks[0]]), of: wrong, source: source,
                tools: tools, work: rejected, stop: stop, progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: rejected.appendingPathComponent("01.flac").path))
    }
}
