import Foundation
import Testing

@testable import CDRipKit

struct CoverArtTests {
    @Test func tellsJPEGFromPNG() {
        #expect(CoverImage(data: Data([0xFF, 0xD8, 0xFF, 0xE0])).fileExtension == "jpg")
        #expect(CoverImage(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])).mimeType == "image/png")
        #expect(CoverImage(data: Data("GIF89a".utf8)).fileExtension == nil)
    }

    @Test func getsTheFrontCover() async throws {
        let transport = FakeTransport([.status(200, body: "\u{FF}"), .status(404)])
        let directory = FileManager.default.temporaryDirectory.appending(path: "CDRipTests-\(UUID())")
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
        let folder = FileManager.default.temporaryDirectory.appending(path: "CDRipTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try CoverImage(data: Data([0xFF, 0xD8, 0xFF, 0xDB])).write(to: folder)
        #expect(url.lastPathComponent == "cover.jpg")
        #expect(throws: CoverArtError.unknownFormat) { try CoverImage(data: Data([1, 2, 3])).write(to: folder) }
    }
}
