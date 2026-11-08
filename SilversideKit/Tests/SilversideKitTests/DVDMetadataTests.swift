import Foundation
import Testing

@testable import SilversideKit

struct DVDMetadataTests {
    func inventory() throws -> DVDInventory {
        let program = try DVDNavigation.presentations(
            ifo: DVDTests().navigation(), titleSet: 1, audioSectors: 200)[0]
        return DVDInventory(
            source: "fixture", volume: "Fixture", fingerprint: "fixture-disc", libraryPath: "", presentations: [program]
        )
    }

    func release() -> MusicBrainzRelease {
        var release = MetadataEditsTests().release()
        release.id = "b66fba4a-655f-4b56-8431-d9c0eddc829b"
        release.media[0].tracks[0].position = 13
        release.media[0].tracks[1].position = 14
        return release
    }

    @Test func selectionDoesNotGuessTrackAssignments() throws {
        let source = try inventory()
        var document = DVDMetadata(inventory: source)
        try document.select(release())
        #expect(try document.names(document.programs[0].tracks[0]).title == "")
        #expect(throws: DVDError.self) { try document.validate(inventory: source, selected: ["1:1"]) }
        try document.map(program: "1:1", medium: 1, assignments: [1: 13])
        #expect(throws: DVDError.self) { try document.validate(inventory: source, selected: ["1:1"]) }
        try document.map(program: "1:1", medium: 1, assignments: [2: 14])
        try document.validate(inventory: source, selected: ["1:1"])
        #expect(try document.names(document.programs[0].tracks[0]).title == "A")
        let comments = try document.comments(program: "1:1", track: 1)
        #expect(comments.contains { $0.key == "TRACKNUMBER" && $0.value == "1" })
        #expect(comments.contains { $0.key == "MUSICBRAINZ_TRACKID" && $0.value == "rec1" })
        #expect(!comments.contains { $0.key == "MUSICBRAINZ_DISCID" })
        // A single MB interview may cover several source chapters, but only by an explicit assignment.
        try document.map(program: "1:1", medium: 1, assignments: [2: 13])
        #expect(document.programs[0].tracks[0].reference == document.programs[0].tracks[1].reference)
    }

    @Test func rejectsWrongDiscAndChangedBoundaries() throws {
        let source = try inventory()
        let document = DVDMetadata(inventory: source)
        var other = source
        other.fingerprint = "other-disc"
        #expect(throws: DVDError.self) { try document.validate(inventory: other) }
        other = source
        other.presentations[0].tracks[0].durationPTS += 1
        #expect(throws: DVDError.self) { try document.validate(inventory: other) }
        other = source
        other.presentations[0].tracks.removeLast()
        #expect(throws: DVDError.self) { try document.validate(inventory: other) }
        #expect(throws: DVDError.self) { try document.validate(inventory: source, selected: ["2:1"]) }
        var duplicate = document
        duplicate.programs.append(duplicate.programs[0])
        #expect(throws: DVDError.self) { try duplicate.validate() }
    }

    @Test func overridesKeepOriginalReleaseAndSafeNames() throws {
        var document = DVDMetadata(inventory: try inventory())
        let original = release()
        try document.select(original)
        try document.map(program: "1:1", medium: 1, assignments: [1: 13, 2: 14])
        try document.set("track1.title=../夢/音楽: = reprise", program: "1:1")
        try document.set("track1.artist=Guest", program: "1:1")
        try document.set("album=Edited")
        #expect(document.release == original)
        let file = try document.filename(program: "1:1", track: 1)
        #expect(!file.contains("/") && !file.contains(":"))
        #expect(file.hasPrefix("01 - ") && file.hasSuffix(".flac"))
        try document.set("track1.title=", program: "1:1")
        #expect(try document.names(document.programs[0].tracks[0]).title == "A")
        #expect(throws: DVDError.self) { try document.set("track3.title=Missing", program: "1:1") }
        #expect(throws: DVDError.self) { try document.set("album=Bad\nName") }
        #expect(throws: DVDError.self) { try document.set("album=Bad\0Name") }
    }

    @Test func invalidMappingAndBulkImportAreAtomic() throws {
        var document = DVDMetadata(inventory: try inventory())
        try document.select(release())
        #expect(throws: DVDError.self) {
            try document.map(program: "1:1", medium: 1, assignments: [1: 13, 2: 999])
        }
        #expect(document.programs[0].tracks.allSatisfy { $0.reference == nil })
        try document.map(program: "1:1", medium: 1, assignments: [1: 13, 2: 14])
        #expect(throws: DVDError.self) { try document.importTitles("First\n", program: "1:1") }
        #expect(throws: DVDError.self) { try document.importTitles("First\n\n", program: "1:1") }
        #expect(document.programs[0].tracks.allSatisfy { $0.title == nil && $0.reference != nil })
        try document.importTitles("第一曲\tArtist A\r\nSecond\tArtist B\r\n", program: "1:1")
        #expect(document.programs[0].tracks.allSatisfy { $0.reference == nil })
        #expect(try document.names(document.programs[0].tracks[0]).artist == "Artist A")
        #expect(try !document.comments(program: "1:1", track: 1).contains { $0.key.hasPrefix("MUSICBRAINZ") })
    }

    @Test func releaseReplacementRequiresClearingMappings() throws {
        var document = DVDMetadata(inventory: try inventory())
        try document.select(release())
        try document.map(program: "1:1", medium: 1, assignments: [1: 13])
        var other = release()
        other.id = "01824c97-a7cf-4817-8bda-760b70d5d7e9"
        #expect(throws: DVDError.self) { try document.select(other) }
        document.clearRelease()
        try document.select(other)
        #expect(document.programs[0].tracks.allSatisfy { $0.reference == nil })
    }

    @Test func persistenceAndReleaseURLValidation() throws {
        let root = try DVDTests().temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("metadata.json")
        var document = DVDMetadata(inventory: try inventory())
        try document.write(to: file)
        try document.set("album=New name")
        #expect(throws: (any Error).self) { try document.write(to: file) }
        #expect(try DVDMetadata.read(from: file).album == nil)
        try document.write(to: file, replacing: true)
        #expect(try DVDMetadata.read(from: file).album == "New name")
        let id = release().id
        #expect(try DVDMetadata.releaseID("https://musicbrainz.org/release/\(id)") == id)
        #expect(try DVDMetadata.releaseID(id.uppercased()) == id)
        for url in [
            "https://example.com/release/\(id)", "https://musicbrainz.org/recording/\(id)", "../../bad", "not-an-id",
        ] {
            #expect(throws: DVDError.self) { try DVDMetadata.releaseID(url) }
        }
        document.version = 99
        #expect(throws: DVDError.self) { try document.write(to: file, replacing: true) }
        #expect(try DVDMetadata.read(from: file).album == "New name")
    }
}
