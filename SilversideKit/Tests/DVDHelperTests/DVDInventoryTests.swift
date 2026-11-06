import Foundation
import SilversideKit
import Testing

@testable import silverside_dvd_helper

struct DVDInventoryTests {
    func fixture(_ root: URL) throws {
        var manager = Data(repeating: 0, count: 2048)
        manager.replaceSubrange(0..<12, with: "DVDAUDIO-AMG".utf8)
        manager[63] = 2
        try manager.write(to: root.appendingPathComponent("AUDIO_TS.IFO"))
        var ifo = Data(repeating: 0, count: 4096)
        ifo.replaceSubrange(0..<12, with: "DVDAUDIO-ATS".utf8)
        func put(_ offset: Int, _ value: Int, _ length: Int) {
            for i in 0..<length { ifo[offset + i] = UInt8((value >> (8 * (length - 1 - i))) & 255) }
        }
        put(204, 1, 4)
        put(2048, 1, 2)
        put(2052, 63, 4)
        put(2056, 0x80, 1)
        put(2060, 16, 4)
        put(2066, 1, 1)
        put(2067, 1, 1)
        put(2068, 90_000, 4)
        put(2074, 16, 2)
        put(2076, 36, 2)
        put(2084, 1, 1)
        put(2086, 660, 4)
        put(2090, 90_000, 4)
        // Cell's first and last sectors both zero.
        for title in 1...2 { try ifo.write(to: root.appendingPathComponent("ATS_0\(title)_0.IFO")) }
        try Data(repeating: 0, count: 2048).write(to: root.appendingPathComponent("ATS_01_1.AOB"))
    }

    @Test func missingOrTruncatedTitleSetDoesNotHideAvailableAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DVDInventory-\(UUID())/AUDIO_TS")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try fixture(root)
        let reader = try #require(DVDDirectory(root.path))
        let inventory = try reader.inventory(source: root.path)
        #expect(inventory.presentations.map(\.id) == ["1:1"])
        #expect(inventory.titleSetIssues?.count == 1)
        #expect(inventory.titleSetIssues?.first?.titleSet == 2)
        #expect(inventory.titleSetIssues?.first?.reason.contains("No AOB") == true)
        try DVDSamples.requireAudio(inventory, titleSet: 1)
        #expect(throws: (any Error).self) { try DVDSamples.requireAudio(inventory, titleSet: 2) }

        try Data(repeating: 0, count: 7).write(to: root.appendingPathComponent("ATS_02_1.AOB"))
        let truncated = try reader.inventory(source: root.path)
        #expect(truncated.presentations.map(\.id) == ["1:1"])
        #expect(truncated.titleSetIssues?.first?.reason.contains("Incomplete AOB") == true)
    }

    @Test func samplesSharedExtentsOnceAndReportsReadFailures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DVDSamples-\(UUID())/AUDIO_TS")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try fixture(root)
        var inventory = try #require(DVDDirectory(root.path)).inventory(source: root.path)
        var duplicate = inventory.presentations[0]
        duplicate.title = 2
        inventory.presentations.append(duplicate)
        var reads = 0
        DVDSamples.collect(&inventory, work: root) { title, first, count, output in
            #expect(title == 1 && first == 0 && count == 1)
            reads += 1
            try Data([1, 2, 3]).write(to: URL(fileURLWithPath: output))
        }
        #expect(reads == 1)
        for program in inventory.presentations {
            #expect(try Data(contentsOf: root.appendingPathComponent(program.sampleFile(track: 1))) == Data([1, 2, 3]))
            #expect(program.trackFormats?.first?.unsupportedReason == nil)
        }
        var failed = try #require(DVDDirectory(root.path)).inventory(source: root.path)
        DVDSamples.collect(&failed, work: root) { _, _, _, _ in throw DVDError("Encrypted fixture") }
        #expect(failed.presentations[0].trackFormats?.first?.unsupportedReason?.contains("Encrypted fixture") == true)
    }
}
