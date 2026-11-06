import Foundation
import Testing

@testable import SilversideKit

struct DVDRunTests {
    /// Minimal MPEG private-stream sectors around generated MLP access units.
    /// One access unit per sector makes track extents independent of compression
    /// ratios. Timestamps use the rate's frame size; this is not a disc authorer.
    func packets(_ stream: Data, startPTS: Int, rate: Int = 48000) throws -> Data {
        let bytes = Array(stream)
        var result = Data()
        var position = 0
        var frame = 0
        while position < bytes.count {
            guard position + 4 <= bytes.count else { throw DVDError("Truncated fixture MLP frame.") }
            let size = (Int(bytes[position] & 15) * 256 + Int(bytes[position + 1])) * 2
            guard size >= 4, position + size <= bytes.count else { throw DVDError("Invalid fixture MLP frame.") }
            let samples = rate >= 176400 ? 160 : rate >= 88200 ? 80 : 40
            let pts = startPTS + frame * samples * 90000 / rate
            let timestamp: [UInt8] = [
                UInt8(0x21 | ((pts >> 29) & 14)), UInt8((pts >> 22) & 255),
                UInt8(((pts >> 14) & 254) | 1), UInt8((pts >> 7) & 255), UInt8(((pts << 1) & 254) | 1),
            ]
            let privateHeader: [UInt8] = [0xa1, 0, 0, 6, 0, 5, 0x63, 0xff, 0, 0]
            let payload = [0x80, 0x80, 5] + timestamp + privateHeader + bytes[position..<position + size]
            var sector: [UInt8] = [0, 0, 1, 0xba, 0x44, 0, 4, 0, 4, 1, 1, 0x89, 0xc3, 0xf8]
            sector += [0, 0, 1, 0xbd, UInt8(payload.count >> 8), UInt8(payload.count & 255)] + payload
            let padding = 2048 - sector.count - 6
            guard padding >= 0 else { throw DVDError("Fixture MLP access unit is too large.") }
            sector += [0, 0, 1, 0xbe, UInt8(padding >> 8), UInt8(padding & 255)]
            sector += [UInt8](repeating: 0xff, count: padding)
            result.append(contentsOf: sector)
            position += size
            frame += 1
        }
        return result
    }

    @Test func independentRunsPreserveSamplesAndTrackCuts() throws {
        guard let ffmpeg = FFmpeg.program() else { return }
        let root = try DVDTests().temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = DVDTools(
            helper: URL(fileURLWithPath: "/usr/bin/false"), ffmpeg: ffmpeg,
            ffprobe: ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe"))
        let stop = StopToken()
        var source = Data()
        var expected = [String]()
        for (index, frequency) in [347, 997].enumerated() {
            let elementary = root.appendingPathComponent("generated-\(index).mlp")
            try DVDExtraction.clean(
                DVDProcess.run(
                    ffmpeg,
                    DVDExtraction.common + [
                        "-f", "lavfi", "-i",
                        "aevalsrc=0.1*sin(2*PI*\(frequency)*t)|0.1*sin(2*PI*\(frequency + 101)*t):s=48000:d=0.25:c=stereo",
                        "-c:a", "mlp", "-strict", "experimental", "-f", "mlp", elementary.path,
                    ], in: root, stop: stop))
            let data = try packets(Data(contentsOf: elementary), startPTS: index == 0 ? 660 : 600)
            #expect(data.count == 300 * 2048)
            source.append(data)
            // Independent reference: decode the elementary stream, without our PES timestamps or cuts.
            let reference = try DVDProcess.run(
                ffmpeg,
                DVDExtraction.common + [
                    "-f", "mlp", "-i", elementary.path, "-map", "0:a:0", "-c:a", "pcm_s24le",
                    "-f", "hash", "-hash", "sha256", "pipe:1",
                ], in: root, stop: stop)
            try DVDExtraction.clean(reference)
            expected.append(try DVDExtraction.hashValue(reference.output))
        }
        let file = root.appendingPathComponent("program.aob")
        try source.write(to: file)
        let tracks = [
            DVDTrack(number: 1, startPTS: 660, durationPTS: 7500, firstSector: 0, lastSector: 99),
            DVDTrack(number: 2, startPTS: 8160, durationPTS: 15000, firstSector: 100, lastSector: 299),
            DVDTrack(number: 3, startPTS: 600, durationPTS: 22500, firstSector: 300, lastSector: 599),
        ]
        var presentation = DVDPresentation(titleSet: 1, title: 1, indexByte: 0x80, durationPTS: 45000, tracks: tracks)
        presentation.format = .init(codec: "mlp", sampleRate: 48000, bits: 24, channels: 2, layout: "stereo")
        try DVDExtraction.validatePackets(file, presentation: presentation)
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        var staged = [URL]()
        var records = [DVDRipReport.Track]()
        for (index, run) in try presentation.decodingRuns().enumerated() {
            let decoded = try DVDExtraction.decodeRun(
                run, of: presentation, source: file, tools: tools, work: work, stop: stop, progress: { _ in })
            #expect(decoded.run.pcmSHA256 == expected[index])
            #expect(decoded.run.frames == 12000)
            records += decoded.tracks
            staged += decoded.files
        }
        #expect(records.map(\.frames) == [4000, 8000, 12000])
        // Each run's track numbering is still global; tags retain the whole-program count.
        let comments = Dictionary(
            try FLACTags.read(staged[2]).map { ($0.key.uppercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(comments["TRACKNUMBER"] == "3/3")
        let destination = root.appendingPathComponent("published")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try DVDExtraction.publish(staged, tracks: records, to: destination)
        #expect(
            records.allSatisfy {
                FileManager.default.fileExists(atPath: destination.appendingPathComponent($0.file).path)
            })
        // Incorrect duration must fail before publishing even when all encoded samples decode cleanly.
        var wrong = presentation
        wrong.tracks[0].durationPTS += 75
        let rejected = root.appendingPathComponent("rejected")
        try FileManager.default.createDirectory(at: rejected, withIntermediateDirectories: false)
        #expect(throws: DVDError.self) {
            try DVDExtraction.decodeRun(
                .init(tracks: Array(wrong.tracks.prefix(2))), of: wrong, source: file,
                tools: tools, work: rejected, stop: stop, progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: rejected.appendingPathComponent("01.flac").path))
        // A later run must not be converted silently to the program's declared precision.
        var wrongFormat = presentation
        wrongFormat.format?.bits = 16
        let changed = root.appendingPathComponent("changed-format")
        try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: false)
        #expect(throws: DVDError.self) {
            try DVDExtraction.decodeRun(
                .init(tracks: [tracks[2]]), of: wrongFormat, source: file,
                tools: tools, work: changed, stop: stop, progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: changed.appendingPathComponent("03.flac").path))
    }
}
