import Foundation
import Testing

@testable import silverside_dvd_helper

struct DVDDirectoryTests {
    @Test func scansAudioAfterSystemHeadersAndOtherPackets() throws {
        var sector = [UInt8](repeating: 0, count: 2048)
        sector.replaceSubrange(0..<4, with: [0, 0, 1, 0xba])
        sector[13] = 7  // Pack stuffing precedes the system header.
        sector.replaceSubrange(21..<33, with: [0, 0, 1, 0xbb, 0, 6, 0, 0, 0, 0, 0, 0])
        sector.replaceSubrange(33..<42, with: [0, 0, 1, 0xbd, 0, 3, 0x80, 0, 0])
        sector.replaceSubrange(42..<51, with: [0, 0, 1, 0xbd, 0, 3, 0x80, 0, 0])
        try DVDPackets.checkAudio(sector[...])
        sector[48] |= 0x30
        #expect(throws: (any Error).self) { try DVDPackets.checkAudio(sector[...]) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SilversideDVDPackets-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("AUDIO_TS")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: false)
        try Data(sector).write(to: audio.appendingPathComponent("ATS_01_1.AOB"))
        let reader = try #require(DVDDirectory(root.path))
        let output = root.appendingPathComponent("read.aob")
        #expect(throws: (any Error).self) { try reader.copy(title: 1, first: 0, count: 1, output: output.path) }
        #expect(try Data(contentsOf: output).isEmpty)
        sector[48] = 0x80
        sector[46] = 0xff  // A packet must not run beyond its own sector.
        #expect(throws: (any Error).self) { try DVDPackets.checkAudio(sector[...]) }
        #expect(throws: (any Error).self) { try DVDPackets.checkAudio(sector.dropLast()) }
    }

    @Test func rangesCrossAOBFilesWithoutOverwriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilversideDVDDirectory-\(UUID())/AUDIO_TS")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Data(repeating: 7, count: 4096).write(to: root.appendingPathComponent("ATS_01_1.AOB"))
        try Data(repeating: 9, count: 6144).write(to: root.appendingPathComponent("ATS_01_2.AOB"))
        let reader = try #require(DVDDirectory(root.path))
        let output = root.appendingPathComponent("read.aob")
        try reader.copy(title: 1, first: 1, count: 3, output: output.path)
        let expected = Data(repeating: 7, count: 2048) + Data(repeating: 9, count: 4096)
        #expect(try Data(contentsOf: output) == expected)
        #expect(throws: (any Error).self) { try reader.copy(title: 1, first: 0, count: 1, output: output.path) }
        #expect(try Data(contentsOf: output) == expected)
        #expect(throws: (any Error).self) {
            try reader.copy(title: 1, first: 4, count: 2, output: root.appendingPathComponent("invalid.aob").path)
        }
        try FileManager.default.moveItem(
            at: root.appendingPathComponent("ATS_01_2.AOB"), to: root.appendingPathComponent("ATS_01_3.AOB"))
        #expect(throws: (any Error).self) { try reader.files(1) }
    }
    @Test func encryptedDirectoryIsNotTreatedAsPlaintext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilversideDVDEncrypted-\(UUID())/AUDIO_TS")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        var packet = Data(repeating: 0, count: 2048)
        packet.replaceSubrange(0..<4, with: [0, 0, 1, 0xba])
        packet.replaceSubrange(14..<23, with: [0, 0, 1, 0xbd, 0, 8, 0xa0, 0x80, 5])
        try packet.write(to: root.appendingPathComponent("ATS_01_1.AOB"))
        let reader = try #require(DVDDirectory(root.path))
        let output = root.appendingPathComponent("read.aob")
        #expect(throws: (any Error).self) { try reader.copy(title: 1, first: 0, count: 1, output: output.path) }
        #expect(try Data(contentsOf: output).isEmpty)
    }
}
