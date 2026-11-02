import Foundation
import Testing

@testable import silverside_dvd_helper

struct DVDDirectoryTests {
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
