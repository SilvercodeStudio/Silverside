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
        // The main front, then the images for a disc, then the rest in the archive's order.
        #expect(CoverArtImage.ordered(images, forDisc: 13).map(\.id) == ["1", "3", "2", "4"])
        #expect(CoverArtImage.ordered(images, forDisc: 3).map(\.id) == ["1", "4", "2", "3"])
        #expect(CoverArtImage.ordered(images, forDisc: 9).map(\.id) == ["1", "2", "3", "4"])
        #expect(CoverArtImage.ordered(images, forDisc: nil).map(\.id) == ["1", "2", "3", "4"])
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

    /// A client whose answers are `answers`, with a cache in `directory`.
    func client(_ answers: [FakeTransport.Answer], in directory: URL) -> (CoverArtClient, FakeTransport) {
        let transport = FakeTransport(answers)
        let client = CoverArtClient(
            client: WebClient(
                directory: directory.appending(path: "cache"), transport: transport,
                policies: ["coverartarchive.org": .init(interval: .zero, lifetime: .seconds(60))]))
        return (client, transport)
    }

    /// A release that MusicBrainz knows, in release group "g", with no images of its own.
    func releaseWithoutArtwork() throws -> MusicBrainzRelease {
        var release = MusicBrainzRelease.manual(toc: try TOC(audioTrackStarts: [0], leadOutLBA: 1000))
        release.id = "epic"
        release.releaseGroup = .init(id: "g", title: "Live", primaryType: "Album", secondaryTypes: [])
        release.artworkCount = 0
        return release
    }

    /// A release with no images takes its release group's, every one of them, and says which
    /// release they came from (*Live at Stubb's*: Epic has none, Or Music has three).
    @Test func takesTheReleaseGroupsArtworkWhenTheReleaseHasNone() async throws {
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
        let directory = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (client, transport) = client(
            [.status(200, body: Self.listing)] + Array(repeating: .bytes(jpeg), count: 5), in: directory)
        let result = try await client.saveArtwork(
            .all, of: try releaseWithoutArtwork(), in: directory.appending(path: "album"))
        guard case .saved(let files, let other) = result else {
            Issue.record("Not saved: \(result)")
            return
        }
        #expect(other == "r" && files.count == 5 && files[0].lastPathComponent == "cover.jpg")
        let urls = await transport.requests.map { $0.url!.absoluteString }
        #expect(urls.first == "https://coverartarchive.org/release-group/g")
    }

    /// A group that has no art at all leaves the release with none; one whose art is the
    /// release's own adds nothing.
    @Test func savesNothingWhenTheGroupHasNone() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (client, _) = client([.status(404)], in: directory)
        let result = try await client.saveArtwork(
            .all, of: try releaseWithoutArtwork(), in: directory.appending(path: "album"))
        #expect(result == .noneInArchive)
    }

    /// The release the user chose for the artwork gives every image, front cover and all.
    @Test func savesTheArtworkOfTheReleaseTheUserChose() async throws {
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
        let directory = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (client, transport) = client(
            [.status(200, body: Self.listing)] + Array(repeating: .bytes(jpeg), count: 5), in: directory)
        var release = try releaseWithoutArtwork()
        release.hasFrontCover = true
        release.artworkCount = 1
        let result = try await client.saveArtwork(
            .all, of: release, in: directory.appending(path: "album"), from: "ormusic")
        guard case .saved(let files, let other) = result else {
            Issue.record("Not saved: \(result)")
            return
        }
        #expect(other == "ormusic" && files.count == 5)
        let urls = await transport.requests.map { $0.url!.absoluteString }
        #expect(urls.first == "https://coverartarchive.org/release/ormusic")
    }

    /// The front cover shown for a release: the chosen release's, its own, or its group's.
    @Test(arguments: [
        (true, nil, "https://coverartarchive.org/release/epic/front"),
        (false, nil, "https://coverartarchive.org/release-group/g/front"),
        (true, "ormusic", "https://coverartarchive.org/release/ormusic/front"),
    ])
    func findsTheFrontCoverThatStandsForTheRelease(ownFront: Bool, source: String?, url: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (client, transport) = client([.bytes([0xFF, 0xD8, 0xFF, 0xE0])], in: directory)
        var release = try releaseWithoutArtwork()
        release.hasFrontCover = ownFront
        #expect(try await client.frontCover(of: release, from: source) != nil)
        #expect(await transport.requests.map { $0.url!.absoluteString } == [url])
    }

    /// Another release's artwork is kept for the release until a cover of its own, or the
    /// archive's again, replaces it.
    @Test func keepsTheOtherReleaseUntilACoverReplacesIt() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ReleaseCoverStore(folder: folder)
        try store.remember(try makeJPEG(width: 10, height: 10), forReleaseID: "epic")
        try store.useArtwork(ofRelease: "ormusic", forReleaseID: "epic")
        #expect(store.artworkRelease(forReleaseID: "epic") == "ormusic" && store.cover(forReleaseID: "epic") == nil)
        try store.remember(try makeJPEG(width: 10, height: 10), forReleaseID: "epic")
        #expect(store.artworkRelease(forReleaseID: "epic") == nil)
        try store.useArtwork(ofRelease: "ormusic", forReleaseID: "epic")
        try store.forget(releaseID: "epic")
        #expect(store.artworkRelease(forReleaseID: "epic") == nil)
    }

    /// A rip folder with old artwork and a disc.json that lists it, and an album folder with a copy.
    func earlierRip(in directory: URL) throws -> (rip: URL, album: URL) {
        let rip = directory.appending(path: "rip", directoryHint: .isDirectory)
        let album = directory.appending(path: "album", directoryHint: .isDirectory)
        for folder in [rip, album] {
            try FileManager.default.createDirectory(
                at: folder.appending(path: "Artwork"), withIntermediateDirectories: true)
            try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: folder.appending(path: "Artwork/back.jpg"))
            try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: folder.appending(path: "Artwork/tray.jpg"))
        }
        let toc = try TOC(audioTrackStarts: [0], leadOutLBA: 1000)
        var report = RipReport(
            drive: .init(vendor: "SIM", product: "DRIVE", revision: "1", readOffset: 6, offsetSource: "test"),
            secure: true, toc: toc, tracks: [], ctdb: .init(status: .notChecked))
        report.files = ["Artwork/back.jpg", "Artwork/tray.jpg", "Track 01.wav", "cover.jpg", "disc.json"]
        try report.write(to: rip.appending(path: "disc.json"))
        return (rip, album)
    }

    /// Another release's images replace an earlier rip's Artwork, and its album's, after the
    /// fact; the rip's report lists the new files.
    @Test func replacesTheArtworkOfAnEarlierRip() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (rip, album) = try earlierRip(in: directory)
        let (client, transport) = client(Array(repeating: .bytes([0xFF, 0xD8, 0xFF, 0xE0]), count: 4), in: directory)
        let images = try CoverArtClient.images(fromJSON: Data(Self.listing.utf8))
        let count = try await client.replaceArtwork(with: images, in: [rip, album, rip])
        #expect(count == 4)
        let expected = ["back.jpg", "booklet-01.jpg", "booklet-02.jpg", "medium.jpg"]
        for folder in [rip, album] {
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "Artwork").path)
            #expect(names.sorted() == expected)
            #expect(ArtworkFolder.count(in: folder) == 4)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                .filter { $0.hasPrefix(".silverside-artwork") }
            #expect(leftovers.isEmpty)
        }
        #expect(
            try RipReport.read(from: rip.appending(path: "disc.json")).files
                == (expected.map { "Artwork/" + $0 } + ["Track 01.wav", "cover.jpg", "disc.json"]).sorted())
        // The front is the cover, which a retag changes: it is not downloaded here.
        #expect(await transport.requests.count == 4)
    }

    /// A download that fails leaves every folder's Artwork as it was.
    @Test func keepsTheOldArtworkWhenADownloadFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (rip, album) = try earlierRip(in: directory)
        let (client, _) = client([.status(500), .status(500), .status(500), .status(500)], in: directory)
        let images = try CoverArtClient.images(fromJSON: Data(Self.listing.utf8))
        await #expect(throws: (any Error).self) { try await client.replaceArtwork(with: images, in: [rip, album]) }
        for folder in [rip, album] {
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "Artwork").path)
            #expect(names.sorted() == ["back.jpg", "tray.jpg"])
        }
        #expect(try RipReport.read(from: rip.appending(path: "disc.json")).files?.contains("Artwork/tray.jpg") == true)
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
        guard case .saved(let files, _) = result else {
            Issue.record("Not saved: \(result)")
            return
        }
        #expect(files.map(\.lastPathComponent) == ["cover.jpg"])
    }

    /// The Artwork folder's images, in name order, from the first folder that has any: the
    /// rip's, else the album's.
    @Test func listsTheArtworkBesideTheCover() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (rip, album) = (root.appending(path: "rip"), root.appending(path: "album"))
        let artwork = album.appending(path: "Artwork")
        try FileManager.default.createDirectory(at: rip, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)
        for name in ["booklet-10.jpg", "back.png", "booklet-02.jpg", ".DS_Store", "notes.txt"] {
            try Data([1]).write(to: artwork.appending(path: name))
        }
        #expect(
            CoverFiles.artwork(in: [rip, album]).map(\.lastPathComponent) == [
                "back.png", "booklet-02.jpg", "booklet-10.jpg",
            ])
        #expect(CoverFiles.artwork(in: [rip]).isEmpty)
    }
}
