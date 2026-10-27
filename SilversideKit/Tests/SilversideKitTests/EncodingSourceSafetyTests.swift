import Foundation
import Testing

@testable import SilversideKit

struct EncodingSourceSafetyTests {
    @Test(arguments: [true, false])
    func symlinkedAlbumStagesSourcesAndKeepsItsReport(sourceThroughAlias: Bool) throws {
        let (folder, library) = try PreEmphasisTests().makeRip(emphasized: [1, 2, 3])
        let root = folder.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        var encoder = DiscEncoder(format: .flac)
        encoder.deEmphasizes = false
        encoder.replayGain = false
        encoder.parallelTracks = 1
        let disc = try RippedDisc(folder: folder)
        let originals = try disc.tracks.map { try disc.audio(of: $0) }
        let files = try encoder.encode(disc, into: library)
        let album = files[0].deletingLastPathComponent()
        let alias = root.appending(path: "library-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: library)
        let albumPart = String(album.path.dropFirst(library.path.count + 1))
        let sourceAlbum = sourceThroughAlias ? alias.appending(path: albumPart) : album
        let source = try RippedDisc(albumReportAt: sourceAlbum.appending(path: "Rip Report.json"))
        encoder.deEmphasizes = true
        encoder.overwrites = true
        let (_, record) = try encoder.encodeWithRecord(source, into: sourceThroughAlias ? library : alias)
        #expect(record?.deEmphasizedTracks == [1, 2, 3])
        for index in files.indices {
            let expected = DeEmphasis.apply(
                .cd(originals[index]), bits: 20, previous: index > 0 ? .cd(originals[index - 1]) : nil)
            #expect(try AudioEncoder.decodeWide(files[index]) == expected)
        }
        let saved = try RipReport.read(from: album.appending(path: "Rip Report.json"))
        #expect(saved.encoding?.deEmphasizedTracks == [1, 2, 3])
    }

    @Test func failedImageLeavesOriginalAlbumRetryable() throws {
        let (folder, library) = try HDCDTests().makeRip(.a(0x13))
        let root = folder.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        var encoder = DiscEncoder(format: .flac)
        encoder.replayGain = false
        let files = try encoder.encode(try RippedDisc(folder: folder), into: library)
        let report = files[0].deletingLastPathComponent().appending(path: "Rip Report.json")
        let originals = try files.map { try Data(contentsOf: $0) }
        let originalReport = try Data(contentsOf: report)
        let originalAudio = try files.flatMap { try AudioEncoder.decode($0) }
        // The album is now the only copy of the original PCM.
        try FileManager.default.removeItem(at: folder)
        let images = root.appending(path: "images")
        try Data("A file blocks creation of the image directory".utf8).write(to: images)
        encoder.images = images
        encoder.overwrites = true
        encoder.decodesHDCD = true
        #expect(throws: (any Error).self) {
            try encoder.encodeWithRecord(try RippedDisc(albumReportAt: report), into: library)
        }
        for (file, original) in zip(files, originals) { #expect(try Data(contentsOf: file) == original) }
        #expect(try Data(contentsOf: report) == originalReport)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: report.deletingLastPathComponent().path)
                .allSatisfy { !$0.hasPrefix(".") })

        try FileManager.default.removeItem(at: images)
        let (_, record) = try encoder.encodeWithRecord(try RippedDisc(albumReportAt: report), into: library)
        #expect(record?.hdcdDecoded == true)
        let image = try #require(record?.image)
        #expect(try AudioEncoder.decode(URL(filePath: image)) == originalAudio)
    }
}
