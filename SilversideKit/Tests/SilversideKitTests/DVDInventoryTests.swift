import Foundation
import Testing

@testable import SilversideKit

struct DVDInventoryTests {
    func linkedVideo() -> (manager: Data, ifo: Data) {
        var manager = Data(repeating: 0, count: 6144)
        manager.replaceSubrange(0..<12, with: "DVDAUDIO-AMG".utf8)
        var ifo = DVDTests().navigation()
        func put(_ data: inout Data, _ at: Int, _ value: Int, _ bytes: Int) {
            for i in 0..<bytes { data[at + i] = UInt8((value >> (8 * (bytes - 1 - i))) & 255) }
        }
        put(&manager, 63, 2, 1)
        put(&manager, 196, 1, 4)
        put(&manager, 200, 2, 4)
        put(&ifo, 192, 1234, 4)
        for table in [2048, 4096] {
            put(&manager, table, 1, 2)
            put(&manager, table + 2, 17, 2)
            let entry = table + 4
            put(&manager, entry, table == 2048 ? 0x44 : 0x82, 1)
            put(&manager, entry + 1, 2, 1)
            put(&manager, entry + 4, 270_000, 4)
            put(&manager, entry + 8, table == 2048 ? 3 : 2, 1)
            put(&manager, entry + 9, 1, 1)
            put(&manager, entry + 10, table == 2048 ? 1234 : 1000, 4)
        }
        return (manager, ifo)
    }

    @Test func videoLinksNeedCorroboratingNavigation() throws {
        let (manager, ifo) = linkedVideo()
        let links = try DVDNavigation.videoReferences(manager: manager, ifo: ifo, titleSet: 2)
        #expect(links[1]?.titleSet == 3 && links[1]?.title == 1)
        let program = try DVDNavigation.presentations(ifo: ifo, titleSet: 2, audioSectors: 0, videoReferences: links)[0]
        #expect(program.tracks.count == 2)
        #expect(program.videoReference?.titleSet == 3)
        #expect(program.unsupportedReason?.contains("DVD-Video") == true)
        #expect(throws: DVDError.self) {
            try DVDNavigation.presentations(ifo: ifo, titleSet: 2, audioSectors: 0)
        }
        // A missing/mismatched link must never excuse missing audio files.
        var unrelated = manager
        unrelated[2048 + 4 + 13] ^= 1
        #expect(try DVDNavigation.videoReferences(manager: unrelated, ifo: ifo, titleSet: 2).isEmpty)
        var badDuration = manager
        badDuration[2048 + 4 + 7] ^= 1
        #expect(throws: DVDError.self) {
            try DVDNavigation.videoReferences(manager: badDuration, ifo: ifo, titleSet: 2)
        }
        for count in [0, 2048, 2051, 4096, 4100, 4113] {
            #expect(throws: DVDError.self) {
                try DVDNavigation.videoReferences(manager: manager.prefix(count), ifo: ifo, titleSet: 2)
            }
        }
    }

    @Test func formatClassificationPreservesUnsupportedAndMissingObservations() throws {
        let surround = DVDAudioFormat(codec: "mlp", sampleRate: 96000, bits: 24, channels: 6, layout: "5.1")
        let five = DVDAudioFormat(codec: "mlp", sampleRate: 96000, bits: 24, channels: 5, layout: "5.0")
        var program = try DVDNavigation.presentations(ifo: DVDTests().navigation(), titleSet: 1, audioSectors: 200)[0]
        program.trackFormats = [.init(number: 1, format: surround), .init(number: 2, format: five)]
        program.classifyFormats()
        #expect(program.format == nil)
        #expect(program.trackFormats?[1].format == five)
        #expect(program.unsupportedReason?.contains("Formats change") == true)
        #expect(program.trackFormats?[1].unsupportedReason != nil)

        program.unsupportedReason = nil
        program.trackFormats = [.init(number: 1, format: surround), .init(number: 2, unsupportedReason: "Read failed")]
        program.classifyFormats()
        #expect(program.format == nil)
        #expect(program.unsupportedReason?.contains("Read failed") == true)

        program.unsupportedReason = nil
        program.trackFormats = [.init(number: 1, format: surround), .init(number: 2, format: surround)]
        program.classifyFormats()
        #expect(program.format == surround && program.unsupportedReason == nil)

        // Old reports remain decodable; a fresh inspection requires helper v2.
        let old = try JSONEncoder().encode(program)
        var object = try #require(JSONSerialization.jsonObject(with: old) as? [String: Any])
        object.removeValue(forKey: "trackFormats")
        object.removeValue(forKey: "videoReference")
        let decoded = try JSONDecoder().decode(
            DVDPresentation.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.trackFormats == nil && decoded.format == surround)
    }

    @Test func probesLaterTracksAfterAnUnsupportedFormat() throws {
        guard let ffmpeg = FFmpeg.program() else { return }
        let root = try DVDTests().temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = DVDTools(
            helper: URL(fileURLWithPath: "/usr/bin/false"), ffmpeg: ffmpeg,
            ffprobe: ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe"))
        var program = try DVDNavigation.presentations(
            ifo: DVDTests().navigation(reset: true), titleSet: 1, audioSectors: 200)[0]
        program.tracks[0].durationPTS = 101  // deliberately nonintegral at 44.1 kHz
        for (track, rate) in zip(program.tracks, [44100, 96000]) {
            let file = root.appendingPathComponent(program.sampleFile(track: track.number))
            let elementary = file.appendingPathExtension("mlp")
            try DVDExtraction.clean(
                DVDProcess.run(
                    ffmpeg,
                    DVDExtraction.common + [
                        "-f", "lavfi", "-i", "anullsrc=r=\(rate):cl=stereo", "-t", "0.1",
                        "-c:a", "mlp", "-strict", "experimental", "-f", "mlp", elementary.path,
                    ], in: root, stop: StopToken()))
            // Header discovery does not use packet timing. The separate extraction fixture checks timed cuts.
            try DVDRunTests().packets(Data(contentsOf: elementary), startPTS: 660).write(to: file)
        }
        var inventory = DVDInventory(
            source: "fixture", volume: "fixture", fingerprint: "fixture", libraryPath: "fixture",
            presentations: [program])
        try tools.inspectFormats(&inventory, work: root, stop: StopToken())
        let result = inventory.presentations[0]
        #expect(result.trackFormats?.map { $0.format?.sampleRate } == [44100, 96000])
        #expect(result.trackFormats?[0].unsupportedReason?.contains("whole samples") == true)
        #expect(result.format == nil && result.unsupportedReason != nil)
        #expect(throws: DVDError.self) { try DVDExtraction.select(inventory, title: "1:1") }
    }
}
