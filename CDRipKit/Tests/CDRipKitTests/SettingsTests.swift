import Foundation
import Testing

@testable import CDRipKit

struct SettingsTests {
    func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "CDRipTests-\(UUID())/settings.json")
    }

    @Test func hasDefaultsWithNoFile() throws {
        let settings = try Settings.load(from: temporaryFile())
        #expect(settings == Settings() && settings.format == .flac && settings.aac.mode == .vbrConstrained)
    }

    /// A file with some keys gives the defaults for the others, so older files still read.
    @Test func readsAFileWithSomeKeys() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"format": "alac", "mp3": {"mode": "cbr"}, "plainPunctuation": true}"#.utf8).write(to: url)
        let settings = try Settings.load(from: url)
        #expect(settings.format == .alac && settings.plainPunctuation && settings.mp3.mode == .cbr)
        #expect(settings.mp3.bitRate == 320 && settings.library == Settings().library)
    }

    @Test func changesOneKey() throws {
        var settings = try Settings().setting("format", to: "mp3")
        settings = try settings.setting("aac.bitRate", to: "192")
        settings = try settings.setting("mp3.extraArguments", to: #"["-q", "0"]"#)
        settings = try settings.setting("library", to: "/Volumes/storage/Music")
        #expect(settings.format == .mp3 && settings.aac.bitRate == 192 && settings.mp3.extraArguments == ["-q", "0"])
        #expect(settings.library == "/Volumes/storage/Music")
        #expect(try settings.value(of: "aac.bitRate") == "192")
        #expect(try settings.resetting("aac.bitRate").aac.bitRate == 256)
        #expect(throws: SettingsError.unknownKey("aac.speed")) { try settings.setting("aac.speed", to: "1") }
        #expect(throws: SettingsError.wrongValue("format")) { try settings.setting("format", to: "ogg") }
        #expect(throws: SettingsError.wrongValue("aac.bitRate")) { try settings.setting("aac.bitRate", to: "fast") }
        // A value that reads as JSON is still text when the setting takes text.
        #expect(try settings.setting("library", to: "2024").library == "2024")
        #expect(try settings.setting("rips", to: "true").rips == "true")
    }

    @Test func savesAndReads() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let settings = try Settings().setting("artwork", to: "all")
        try settings.save(to: url)
        #expect(try Settings.load(from: url) == settings)
        try Data("{ not json".utf8).write(to: url)
        #expect(throws: SettingsError.self) { try Settings.load(from: url) }
    }
}

/// A file from a newer version keeps its keys when this version saves it.
struct ForwardCompatibilityTests {
    @Test func keepsTheProfileKeysOfANewerVersion() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "CDRipTests-\(UUID())/DriveProfiles.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            #"{"A B 1": {"vendor": "A", "product": "B", "revision": "1", "manualOffset": 6, "observations": [], "futureField": 42}}"#
                .utf8
        ).write(to: url)
        var store = try DriveProfileStore(url: url)
        var profile = store.profile(vendor: "A", product: "B", revision: "1")
        #expect(profile.manualOffset == 6)
        profile.manualOffset = nil
        profile.cacheSectors = 32
        try store.save(profile)
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: Any]]
        #expect(file?["A B 1"]?["futureField"] as? Int == 42)
        // A value cleared on purpose is cleared in the file.
        #expect(try DriveProfileStore(url: url).profile(vendor: "A", product: "B", revision: "1").manualOffset == nil)
        #expect(try DriveProfileStore(url: url).profile(vendor: "A", product: "B", revision: "1").cacheSectors == 32)
    }

    @Test func keepsTheSettingsOfANewerVersion() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "CDRipTests-\(UUID())/settings.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"format": "alac", "futureSetting": "x", "aac": {"bitRate": 192, "futureAAC": 1}}"#.utf8).write(
            to: url)
        try Settings.load(from: url).setting("format", to: "flac").save(to: url)
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(file?["futureSetting"] as? String == "x" && file?["format"] as? String == "flac")
        #expect((file?["aac"] as? [String: Any])?["futureAAC"] as? Int == 1)
        #expect(try Settings.load(from: url).aac.bitRate == 192)
    }
}
