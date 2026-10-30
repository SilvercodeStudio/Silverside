import Foundation
import Testing
import UniformTypeIdentifiers

@testable import SilversideKit

struct CoverArtTests {
    @Test func tellsJPEGFromPNG() {
        #expect(CoverImage(data: Data([0xFF, 0xD8, 0xFF, 0xE0])).fileExtension == "jpg")
        #expect(CoverImage(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])).mimeType == "image/png")
        #expect(CoverImage(data: Data("GIF89a".utf8)).fileExtension == nil)
    }

    /// WebP, HEIC, TIFF: anything the tags cannot hold becomes a JPEG at full size.
    @Test func convertsAnImageThatTagsCannotHold() throws {
        let jpeg = try makeJPEG(width: 20, height: 10)
        #expect(try CoverImage(converting: jpeg.data) == jpeg)
        let tiff = try makeImage(width: 1600, height: 1200, type: .tiff)
        #expect(tiff.fileExtension == nil)
        let converted = try CoverImage(converting: tiff.data)
        #expect(converted.fileExtension == "jpg")
        let embedded = try EmbeddedCover(converted, maximumPixels: 2000)
        #expect(embedded.width == 1600 && embedded.height == 1200)
        #expect(throws: CoverArtError.notAnImage) { try CoverImage(converting: Data("not an image".utf8)) }
        // A drawing is not a picture: ImageIO does not read SVG, so the file panels leave it out.
        let svg =
            #"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>"#
        #expect(throws: CoverArtError.notAnImage) { try CoverImage(converting: Data(svg.utf8)) }
        #expect(CoverImage.readableTypes.contains(.jpeg) && CoverImage.readableTypes.contains(.webP))
        #expect(!CoverImage.readableTypes.contains(.svg) && !CoverImage.readableTypes.contains(.pdf))
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

    /// Box-set sleeves, as *Summer Magic 1985* has them: thumbnails, and the discs each is for.
    @Test func readsThumbnailsAndTheDiscsOfASleeve() throws {
        let listing = """
            {"images": [
              {"id": 1, "types": ["Front"], "front": true, "comment": "Outer box, front",
               "image": "http://coverartarchive.org/release/r/1.png",
               "thumbnails": {"250": "http://coverartarchive.org/release/r/1-250.jpg", "small": "http://x/1-s.jpg"}},
              {"id": 2, "types": ["Front"], "front": false,
               "comment": "Greek Theatre, Berkeley, CA — 1985-06-14 (Mediums 1–2)",
               "image": "http://coverartarchive.org/release/r/2.png", "thumbnails": {"small": "http://x/2-s.jpg"}},
              {"id": 3, "types": ["Front"], "front": false, "comment": "Hershey Park Stadium (Mediums 12 - 14)",
               "image": "http://coverartarchive.org/release/r/3.png"},
              {"id": 4, "types": ["Medium"], "front": false, "comment": "Disc 3",
               "image": "http://coverartarchive.org/release/r/4.png"}
            ]}
            """
        let images = try CoverArtClient.images(fromJSON: Data(listing.utf8))
        #expect(images[0].thumbnailURL?.absoluteString == "https://coverartarchive.org/release/r/1-250.jpg")
        #expect(images[1].thumbnailURL?.absoluteString == "https://x/2-s.jpg" && images[2].thumbnailURL == nil)
        #expect(images.map(\.mediums) == [nil, 1...2, 12...14, 3...3])
        // A disc's sleeve is a front that names it, not the main front, nor a photo of the disc.
        #expect(CoverArtImage.sleeve(forDisc: 2, in: images)?.id == "2")
        #expect(CoverArtImage.sleeve(forDisc: 3, in: images) == nil)
        let plan = CoverArtImage.sleeves(for: Array(1...14), in: images)
        #expect(plan.sleeves.map(\.image.id) == ["2", "3"] && plan.sleeves.map(\.discs) == [[1, 2], [12, 13, 14]])
        #expect(plan.others == Array(3...11))
    }

    /// The sleeves rule is kept for the release, and a cover for the whole set ends it.
    @Test func keepsTheSleevesRuleUntilASetCoverReplacesIt() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ReleaseCoverStore(folder: folder)
        #expect(!store.usesDiscSleeves(releaseID: "rel"))
        try store.useDiscSleeves(true, releaseID: "rel")
        #expect(store.usesDiscSleeves(releaseID: "rel") && !store.usesDiscSleeves(releaseID: "other"))
        try store.remember(try makeJPEG(width: 10, height: 10), forReleaseID: "rel")
        #expect(!store.usesDiscSleeves(releaseID: "rel") && store.cover(forReleaseID: "rel") != nil)
        try store.useDiscSleeves(true, releaseID: "rel")
        try store.forget(releaseID: "rel")
        #expect(!store.usesDiscSleeves(releaseID: "rel") && store.cover(forReleaseID: "rel") == nil)
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

    /// When the archive's list of images fails, the rip still gets the front cover, which the
    /// app fetched as the disc was read.
    @Test func savesTheFrontWhenTheListFails() async throws {
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
        let transport = FakeTransport([.status(502), .bytes(jpeg)])
        let directory = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = CoverArtClient(
            client: WebClient(
                directory: directory.appending(path: "cache"), transport: transport,
                policies: ["coverartarchive.org": .init(interval: .zero, lifetime: .seconds(60))]))
        var archived = MusicBrainzRelease.manual(toc: try TOC(audioTrackStarts: [0], leadOutLBA: 1000))
        archived.id = "r"
        archived.hasFrontCover = true
        let result = try await client.saveArtwork(.all, of: archived, in: directory.appending(path: "album"))
        guard case .saved(let files) = result else {
            Issue.record("Not saved: \(result)")
            return
        }
        #expect(files.map(\.lastPathComponent) == ["cover.jpg"])
    }
}
