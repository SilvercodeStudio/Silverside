import Foundation
import Testing

@testable import SilversideKit

struct EncodingTests {
    /// A rip folder of a 2-track disc, disc 2 of a 2-disc release, with a cover.
    func makeRip(verified: Bool = true) throws -> (folder: URL, library: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        let folder = root.appending(path: "rip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let toc = try TOC(audioTrackStarts: [0, 75], leadOutLBA: 150)
        let samples = Array(AudioEncoderTests.samples.prefix(75 * 588))
        for number in 1...2 { try WAVFile.write(samples, to: folder.appending(path: "Track 0\(number).wav")) }
        try makeJPEG(width: 1400, height: 1400).write(to: folder)
        func track(_ position: Int, _ title: String) -> MusicBrainzRelease.Track {
            .init(
                position: position, number: String(position), title: title, length: 1000,
                artistCredit: [.init(name: "Grateful Dead")], recordingID: "rec\(position)")
        }
        let release = MusicBrainzRelease(
            id: "rel", title: "Saint of Circumstance: Giants Stadium · East Rutherford · NJ · 6/17/91",
            artistCredit: [.init(name: "Grateful Dead")], date: "2019-09-27", country: "XE", status: "Official",
            barcode: "603497852376", disambiguation: nil, labels: [], releaseGroup: nil,
            media: [
                .init(
                    position: 1, format: "CD", title: nil, discIDs: [],
                    tracks: [track(1, "A"), track(2, "B"), track(3, "C")]),
                .init(
                    position: 2, format: "CD", title: nil, discIDs: [],
                    tracks: [track(1, "Help on the Way >"), track(2, "Slipknot!")]),
            ], hasFrontCover: true)
        var report = RipReport(
            drive: .init(vendor: "V", product: "P", revision: "1", readOffset: 6, offsetSource: "test"), secure: true,
            toc: toc,
            tracks: (1...2).map {
                .init(
                    number: $0, file: "Track 0\($0).wav", startLBA: ($0 - 1) * 75, sectors: 75, preEmphasis: false,
                    accurateRip: verified || $0 == 1 ? .accurate : .notAccurate, ctdbConfidence: 0)
            }, ctdb: .init(status: verified ? .verified : .notVerified))
        report.tracks[0].isrc = "USRH11900001"
        report.release = release
        try report.write(to: folder.appending(path: "disc.json"))
        return (folder, root.appending(path: "library"))
    }

    @Test func encodesIntoTheLibraryLayout() throws {
        let (folder, library) = try makeRip()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let disc = try RippedDisc(folder: folder)
        #expect(disc.tracks.allSatisfy(\.isVerified) && disc.tracks[0].isrc == "USRH11900001")
        let files = try DiscEncoder(format: .flac).encode(disc, into: library)
        let album = "Grateful Dead/Saint of Circumstance- Giants Stadium · East Rutherford · NJ · 6-17-91"
        #expect(
            files.map { $0.path.replacingOccurrences(of: library.path + "/", with: "") } == [
                "\(album)/02-01 Help on the Way.flac", "\(album)/02-02 Slipknot!.flac",
            ])
        // The segue mark stays in the tag and leaves the file name, as the user's library has it.
        let tags = Dictionary(try FLACTags.read(files[0]).map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(tags["TITLE"] == "Help on the Way >" && tags["DISCNUMBER"] == "2" && tags["ISRC"] == "USRH11900001")
        #expect(try FLACTags.readFrontCover(files[0]).map { try EmbeddedCover(CoverImage(data: $0)).width } == 1000)
        #expect(FileManager.default.fileExists(atPath: library.appending(path: "\(album)/cover.jpg").path))
        #expect(throws: EncodingError.self) { try DiscEncoder(format: .flac).encode(disc, into: library) }
        var again = DiscEncoder(format: .flac)
        again.overwrites = true
        #expect(try again.encode(disc, into: library).count == 2)
    }

    @Test func putsTheReportInTheAlbumFolderAndDeletesOnlyTheRipsFiles() throws {
        let (folder, library) = try makeRip()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let disc = try RippedDisc(folder: folder)
        let files = try DiscEncoder(format: .flac).encode(disc, into: library)
        let report = files[0].deletingLastPathComponent().appending(path: "Rip Report (Disc 2).json")
        #expect(try RipReport.read(from: report).toc == disc.toc.ctdbTOCString)

        // Another file in the folder keeps the folder; the rip's own files go.
        try Data("mine".utf8).write(to: folder.appending(path: "notes.txt"))
        try disc.deleteRipFiles()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["notes.txt"])
        try FileManager.default.removeItem(at: folder.appending(path: "notes.txt"))
        let (second, secondLibrary) = try makeRip()
        defer { try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }
        let secondDisc = try RippedDisc(folder: second)
        _ = try DiscEncoder(format: .flac).encode(secondDisc, into: secondLibrary)
        try secondDisc.deleteRipFiles()
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    /// The rip's report lists the files it wrote: only those go, so the user's own files in
    /// the folder stay. The other artwork is copied to the album folder before that.
    @Test func deletesOnlyTheFilesTheRipListed() throws {
        let (folder, library) = try makeRip()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let artwork = folder.appending(path: "Artwork", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: artwork.appending(path: "back.jpg"))
        // The user's own files, which the rip did not write.
        try Data("mine".utf8).write(to: artwork.appending(path: "scan.jpg"))
        try Data("mine".utf8).write(to: folder.appending(path: "cover.png"))
        var report = try RipReport.read(from: folder.appending(path: "disc.json"))
        report.files = ["Track 01.wav", "Track 02.wav", "disc.json", "Rip Report.md", "cover.jpg", "Artwork/back.jpg"]
        try report.write(to: folder.appending(path: "disc.json"))
        let disc = try RippedDisc(folder: folder)
        let files = try DiscEncoder(format: .flac).encode(disc, into: library)
        let album = files[0].deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: album.appending(path: "Artwork/back.jpg").path))
        try disc.deleteRipFiles()
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["Artwork", "cover.png"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: artwork.path) == ["scan.jpg"])
    }

    /// A file that exists stops the encoding before any file is written.
    @Test func checksEveryFileBeforeWritingAny() throws {
        let (folder, library) = try makeRip()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let disc = try RippedDisc(folder: folder)
        let files = try DiscEncoder(format: .flac).encode(disc, into: library)
        try FileManager.default.removeItem(at: files[1])
        #expect(throws: EncodingError.exists(files[0])) { try DiscEncoder(format: .flac).encode(disc, into: library) }
        #expect(!FileManager.default.fileExists(atPath: files[1].path))
    }

    @Test func refusesUnverifiedTracks() throws {
        let (folder, library) = try makeRip(verified: false)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let disc = try RippedDisc(folder: folder)
        #expect(throws: EncodingError.notVerified(track: 2)) {
            try DiscEncoder(format: .flac).encode(disc, into: library)
        }
        var encoder = DiscEncoder(format: .alac)
        encoder.allowsUnverified = true
        #expect(try encoder.encode(disc, into: library).count == 2)
    }
}
