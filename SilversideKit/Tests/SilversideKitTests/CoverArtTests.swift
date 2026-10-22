import Foundation
import Testing

@testable import SilversideKit

struct CoverArtTests {
    @Test func tellsJPEGFromPNG() {
        #expect(CoverImage(data: Data([0xFF, 0xD8, 0xFF, 0xE0])).fileExtension == "jpg")
        #expect(CoverImage(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])).mimeType == "image/png")
        #expect(CoverImage(data: Data("GIF89a".utf8)).fileExtension == nil)
    }

    @Test func getsTheFrontCover() async throws {
        let transport = FakeTransport([.status(200, body: "\u{FF}"), .status(404)])
        let directory = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = CoverArtClient(
            client: WebClient(
                directory: directory, transport: transport,
                policies: ["coverartarchive.org": .init(interval: .zero, lifetime: .seconds(60))]))
        #expect(try await client.frontCover(releaseID: "abc") != nil)
        #expect(try await client.frontCover(releaseID: "none") == nil)
        let urls = await transport.requests.map { $0.url!.absoluteString }
        #expect(
            urls == ["https://coverartarchive.org/release/abc/front", "https://coverartarchive.org/release/none/front"])
    }

    @Test func writesTheCoverWithItsExtension() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try CoverImage(data: Data([0xFF, 0xD8, 0xFF, 0xDB])).write(to: folder)
        #expect(url.lastPathComponent == "cover.jpg")
        #expect(throws: CoverArtError.unknownFormat) { try CoverImage(data: Data([1, 2, 3])).write(to: folder) }
    }
}

struct CoverArtListingTests {
    static let listing = """
        {"images": [
          {"id": 101, "types": ["Front"], "front": true, "back": false, "comment": "",
           "image": "http://coverartarchive.org/release/r/101.jpg"},
          {"id": "102", "types": ["Back"], "front": false, "back": true, "comment": "",
           "image": "http://coverartarchive.org/release/r/102.jpg"},
          {"id": 103, "types": ["Booklet"], "front": false, "back": false, "comment": "page 1",
           "image": "http://coverartarchive.org/release/r/103.jpg"},
          {"id": 104, "types": ["Booklet"], "front": false, "back": false, "comment": "page 2",
           "image": "http://coverartarchive.org/release/r/104.png"},
          {"id": 105, "types": ["Medium", "Raw/Unedited"], "front": false, "back": false,
           "image": "http://coverartarchive.org/release/r/105.jpg"}
        ], "release": "https://musicbrainz.org/release/r"}
        """

    @Test func readsTheListing() throws {
        let images = try CoverArtClient.images(fromJSON: Data(Self.listing.utf8))
        #expect(images.map(\.id) == ["101", "102", "103", "104", "105"])
        #expect(images[0].isFront && images[1].isBack && images[2].comment == "page 1")
        #expect(images.allSatisfy { $0.url.scheme == "https" })
        #expect(throws: CoverArtError.malformedListing) { try CoverArtClient.images(fromJSON: Data("{}".utf8)) }
    }

    @Test func namesTheImagesByType() throws {
        let images = try CoverArtClient.images(fromJSON: Data(Self.listing.utf8))
        #expect(
            CoverArtImage.fileNames(for: Array(images.dropFirst())) == ["back", "booklet-01", "booklet-02", "medium"])
    }

    @Test func savesTheFrontAndTheRest() async throws {
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let transport = FakeTransport(
            [.status(200, body: Self.listing)] + [jpeg, jpeg, jpeg, png, jpeg].map { .bytes($0) })
        let directory = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = CoverArtClient(
            client: WebClient(
                directory: directory.appending(path: "cache"), transport: transport,
                policies: ["coverartarchive.org": .init(interval: .zero, lifetime: .seconds(60))]))
        let files = try await client.save(releaseID: "r", in: directory.appending(path: "album"), all: true)
        #expect(
            files.map { $0.path.replacingOccurrences(of: directory.path + "/album/", with: "") } == [
                "cover.jpg", "Artwork/back.jpg", "Artwork/booklet-01.jpg", "Artwork/booklet-02.png",
                "Artwork/medium.jpg",
            ])
    }
}
