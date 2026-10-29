import AppKit
import Foundation
import Testing

@testable import SilversideKit

struct EncodingTests {
    /// A rip folder of a 2-track disc, disc 2 of a 2-disc release, with a cover. Disc 1 has
    /// 3 tracks, in a folder of its own beside it (`disc1`), with quieter audio.
    func makeRip(verified: Bool = true, disc1: Bool = false) throws -> (folder: URL, library: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        let folder = root.appending(path: disc1 ? "rip1" : "rip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let count = disc1 ? 3 : 2
        let toc = try TOC(audioTrackStarts: (0..<count).map { $0 * 75 }, leadOutLBA: count * 75)
        let samples = Array(AudioEncoderTests.samples.prefix(75 * 588)).map {
            // Disc 1 is about 12 dB quieter: each channel's value divided by 4.
            disc1
                ? UInt32(UInt16(bitPattern: Int16(bitPattern: UInt16($0 & 0xFFFF)) / 4)) | UInt32(
                    UInt16(bitPattern: Int16(bitPattern: UInt16($0 >> 16)) / 4)) << 16 : $0
        }
        for number in 1...count { try WAVFile.write(samples, to: folder.appending(path: "Track 0\(number).wav")) }
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
            tracks: (1...count).map {
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
        // ReplayGain: the test rip's audio is noise, so it has a loudness; the album's covers both tracks.
        #expect(tags["REPLAYGAIN_TRACK_GAIN"]?.hasSuffix(" dB") == true && tags["REPLAYGAIN_ALBUM_PEAK"] != nil)
        #expect(tags["REPLAYGAIN_REFERENCE_LOUDNESS"] == "-18.00 LUFS")
        #expect(try FLACTags.readFrontCover(files[0]).map { try EmbeddedCover(CoverImage(data: $0)).width } == 1000)
        #expect(FileManager.default.fileExists(atPath: library.appending(path: "\(album)/cover.jpg").path))
        #expect(throws: EncodingError.self) { try DiscEncoder(format: .flac).encode(disc, into: library) }
        var again = DiscEncoder(format: .flac)
        again.overwrites = true
        #expect(try again.encode(disc, into: library).count == 2)
    }

    /// A disc image: every track in one file, beside the library, checked, with a CUE sheet
    /// that names the one file and the album's tags.
    /// The lanes finish in any order, but the log names the files in the tracks' order.
    @Test func logsTheFilesInTrackOrder() throws {
        final class Lines: @unchecked Sendable {
            private let lock = NSLock()
            private var all = [String]()
            func append(_ line: String) { lock.withLock { all.append(line) } }
            var lines: [String] { lock.withLock { all } }
        }
        let (folder, library) = try makeRip(disc1: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        for _ in 0..<10 {
            try? FileManager.default.removeItem(at: library)
            let lines = Lines()
            var encoder = DiscEncoder(format: .flac)
            encoder.parallelTracks = 3
            encoder.log = { lines.append($0) }
            let files = try encoder.encode(try RippedDisc(folder: folder), into: library)
            #expect(lines.lines.filter { $0.hasSuffix(".flac") } == files.map(\.lastPathComponent))
        }
    }

    @Test func writesADiscImage() throws {
        let (folder, library) = try makeRip()
        let root = folder.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let disc = try RippedDisc(folder: folder)
        let whole = try disc.tracks.flatMap { try WAVFile.read($0.file) }
        var encoder = DiscEncoder(format: .flac)
        encoder.images = root.appending(path: "images")
        let (_, record) = try encoder.encodeWithRecord(disc, into: library)
        let album = "Grateful Dead/Saint of Circumstance- Giants Stadium · East Rutherford · NJ · 6-17-91"
        let name = "Saint of Circumstance- Giants Stadium · East Rutherford · NJ · 6-17-91 (Disc 2)"
        let image = root.appending(path: "images/\(album)/\(name).flac")
        #expect(record?.image == image.path)
        #expect(try AudioEncoder.decode(image) == whole)
        let cue = try String(contentsOf: image.deletingPathExtension().appendingPathExtension("cue"), encoding: .utf8)
        #expect(cue.contains("FILE \"\(name).flac\" WAVE\n  TRACK 01 AUDIO"))
        #expect(cue.contains("  TRACK 02 AUDIO\n    TITLE \"Slipknot!\"") && cue.contains("INDEX 01 00:01:00"))
        let tags = Dictionary(try FLACTags.read(image).map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(tags["ALBUM"] == tags["TITLE"])
        #expect(tags["DISCNUMBER"] == "2")
        #expect(tags["CUESHEET"] == cue)
        #expect(tags["TRACKNUMBER"] == nil && tags["ISRC"] == nil)
        let report = try RipReport.read(from: library.appending(path: "\(album)/Rip Report (Disc 2).json"))
        #expect(report.encoding?.image == image.path)

        // A library in a lossy format gets a FLAC image; a WAV library, a WAV image.
        encoder.format = .aac
        encoder.overwrites = true
        #expect(try encoder.encodeWithRecord(disc, into: library).encoding?.image == image.path)
        encoder.format = .wav
        let wav = try #require(try encoder.encodeWithRecord(disc, into: library).encoding?.image)
        #expect(wav.hasSuffix(".wav"))
        #expect(try WAVFile.read(URL(filePath: wav)) == whole)
    }

    /// A box set's disc with its own sleeve: its files embed the sleeve, and the album folder
    /// keeps the set's cover beside "cover (Disc 2)". A library update can take the sleeve
    /// away, or give another.
    @Test func embedsADiscsOwnSleeve() throws {
        let (folder, library) = try makeRip()
        let root = folder.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeJPEG(width: 600, height: 600).write(to: folder, name: "cover (Disc 2)")
        let disc = try RippedDisc(folder: folder)
        #expect(disc.coverFile?.lastPathComponent == "cover (Disc 2).jpg")
        let (files, _) = try DiscEncoder(format: .flac).encodeWithRecord(disc, into: library)
        func embeddedWidth(_ file: URL) throws -> Int? {
            try FLACTags.readFrontCover(file).map { try EmbeddedCover(CoverImage(data: $0)).width }
        }
        #expect(try embeddedWidth(files[0]) == 600)
        let album = files[0].deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: album.appending(path: "cover (Disc 2).jpg").path))
        #expect(try CoverImage(data: Data(contentsOf: album.appending(path: "cover.jpg"))).data.count > 0)

        // The disc takes the set's cover again, then a sleeve of 300 pixels.
        let stores = (
            ReleaseEditsStore(url: root.appending(path: "edits.json")),
            ReleaseCoverStore(folder: root.appending(path: "covers"))
        )
        _ = try DiscEncoder(format: .flac).updateLibrary(
            reportAt: folder.appending(path: "disc.json"), discCover: .remove, library: library,
            editsStore: stores.0, coverStore: stores.1)
        #expect(try embeddedWidth(files[0]) == 1000)
        #expect(CoverFiles.disc(2, in: album) == nil && CoverFiles.disc(2, in: folder) == nil)
        _ = try DiscEncoder(format: .flac).updateLibrary(
            reportAt: folder.appending(path: "disc.json"), discCover: .set(try makeJPEG(width: 300, height: 300)),
            library: library, editsStore: stores.0, coverStore: stores.1)
        #expect(try embeddedWidth(files[0]) == 300)
        #expect(CoverFiles.disc(2, in: album) != nil && CoverFiles.disc(2, in: folder) != nil)
        // The rip's files go, its sleeve with them.
        try disc.deleteRipFiles()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// The lanes give the same files, in the tracks' order, however many there are.
    @Test func encodesTheSameOnOneLaneAndSeveral() throws {
        let (folder, library) = try makeRip()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let disc = try RippedDisc(folder: folder)
        var one = DiscEncoder(format: .flac)
        one.parallelTracks = 1
        let serial = try one.encode(disc, into: library)
        let bytes = try serial.map { try Data(contentsOf: $0) }
        var several = DiscEncoder(format: .flac)
        several.parallelTracks = 3
        several.overwrites = true
        let (files, record) = try several.encodeWithRecord(disc, into: library)
        #expect(files == serial)
        #expect(try files.map { try Data(contentsOf: $0) } == bytes)
        #expect(record?.files.map(\.track) == [1, 2] && (record?.seconds ?? -1) >= 0)
        #expect(DiscEncoder.defaultParallelTracks >= 2 && DiscEncoder.defaultParallelTracks <= 4)
    }

    /// A rip of some tracks only: each file is recorded and in the CUE sheet. The encoder once
    /// looked its jobs up by their track's index, not their place, and lost every track but one.
    @Test func recordsEveryTrackOfARipOfSomeTracks() throws {
        let (folder, library) = try makeRip()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        var report = try RipReport.read(from: folder.appending(path: "disc.json"))
        report.tracks.removeFirst()
        try report.write(to: folder.appending(path: "disc.json"))
        try FileManager.default.removeItem(at: folder.appending(path: "Track 01.wav"))
        let (files, record) = try DiscEncoder(format: .flac).encodeWithRecord(RippedDisc(folder: folder), into: library)
        #expect(files.count == 1 && record?.files.map(\.track) == [2])
        let cue = try #require(
            FileManager.default.contentsOfDirectory(
                at: files[0].deletingLastPathComponent(), includingPropertiesForKeys: nil
            )
            .first { $0.pathExtension == "cue" })
        #expect(try String(contentsOf: cue, encoding: .utf8).contains("TRACK 02 AUDIO"))
    }

    /// The album folder's report says how the files were made: the format, the encoder and
    /// its settings, and each track's file; the Markdown says it too.
    @Test func recordsTheEncodingInTheAlbumFoldersReport() throws {
        let (folder, library) = try makeRip()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let disc = try RippedDisc(folder: folder)
        var encoder = DiscEncoder(format: .aac)
        encoder.aac.mode = .cbr
        encoder.aac.bitRate = 192
        let (files, record) = try encoder.encodeWithRecord(disc, into: library)
        let album = files[0].deletingLastPathComponent()
        let saved = try #require(try RipReport.read(from: album.appending(path: "Rip Report (Disc 2).json")).encoding)
        #expect(saved == record)
        #expect(saved.format == .aac && saved.encoder == "Apple AudioToolbox" && saved.mp3 == nil)
        #expect(saved.settingsText == "constant 192 kbit/s" && saved.folder == album.path)
        #expect(saved.files.map(\.track) == [1, 2] && saved.file(ofTrack: 2) == files[1].lastPathComponent)
        #expect(saved.replayGain?.tracks.map(\.track) == [1, 2] && saved.replayGain?.album != nil)
        #expect(try MP4Tags.read(files[0]).comments.contains { $0.key == "REPLAYGAIN_ALBUM_GAIN" })
        let markdown = try String(contentsOf: album.appending(path: "Rip Report (Disc 2).md"), encoding: .utf8)
        #expect(
            markdown.contains("## Encoding") && markdown.contains("AAC, by Apple AudioToolbox (constant 192 kbit/s)"))
        // The rip's own disc.json is the encoder's input, and stays as it was.
        #expect(try RipReport.read(from: folder.appending(path: "disc.json")).encoding == nil)
    }

    /// An archive manifest keeps its report under "ripReport", so the record goes in there.
    @Test func savesTheEncodingInsideAManifestsReport() throws {
        let (folder, _) = try makeRip()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "disc.json")))
        let manifest = folder.appending(path: "manifest.json")
        try JSONSerialization.data(withJSONObject: ["ripReport": report, "archive": "kept"]).write(to: manifest)
        let record = RipReport.Encoding(format: .flac, encoder: "Apple AudioToolbox", folder: "/x", files: [])
        try record.save(inReportAt: manifest)
        #expect(try RipReport.read(from: manifest).encoding?.format == .flac)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        #expect(object?["archive"] as? String == "kept" && object?["encoding"] == nil)
    }

    /// A change to a manifest's report goes under "ripReport" too, where `RippedDisc` reads
    /// it, and the root gets no second copy that `RipReport.read` would prefer (review of 0.9).
    @Test func updatesTheReportInsideAManifest() throws {
        let (folder, _) = try makeRip()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let file = folder.appending(path: "disc.json")
        let original = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let manifest: [String: Any] = [
            "toc": original["toc"]!, "release": original["release"]!, "ripReport": original, "archive": "kept",
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: file)
        try RipReport.update(reportAt: file) {
            $0.dataTracks = [
                .init(number: 3, startLBA: 13100, file: "Track 03.iso", sectors: 300, mode: .mode1, crc32: "12345678")
            ]
        }
        #expect(try RipReport.read(from: file).dataTracks?.count == 1)
        #expect(try RippedDisc(folder: folder).report?.dataTracks?.count == 1)
        let updated = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let nested = try #require(updated["ripReport"] as? [String: Any])
        #expect((nested["dataTracks"] as? [[String: Any]])?.count == 1)
        #expect(updated["dataTracks"] == nil && updated["archive"] as? String == "kept")
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

    /// A cover the rip found in its folder already (from an earlier attempt) is not in its
    /// list, but the album folder has the same file: it goes, and so does the folder. A file
    /// of the user's that the album folder does not have stays.
    @Test func deletesTheCopiesThatTheAlbumFolderKeeps() throws {
        let (folder, library) = try makeRip()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let disc = try RippedDisc(folder: folder)
        let files = try DiscEncoder(format: .flac).encode(disc, into: library)
        let album = files[0].deletingLastPathComponent()
        let artwork = folder.appending(path: "Artwork", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: album.appending(path: "Artwork"), withIntermediateDirectories: true)
        for place in [artwork, album.appending(path: "Artwork")] {
            try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: place.appending(path: "front-01.jpg"))
        }
        try Data("mine".utf8).write(to: folder.appending(path: "notes.txt"))
        try disc.deleteRipFiles(albumFolder: album)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["notes.txt"])
        #expect(FileManager.default.fileExists(atPath: album.appending(path: "Artwork/front-01.jpg").path))
        try FileManager.default.removeItem(at: folder.appending(path: "notes.txt"))
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: folder.appending(path: "cover (old).jpg"))
        try FileManager.default.copyItem(
            at: folder.appending(path: "cover (old).jpg"), to: album.appending(path: "cover (old).jpg"))
        try disc.deleteRipFiles(albumFolder: album)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// An album folder that is the rip's folder, or inside it, would lose its files with the
    /// rip's: nothing goes.
    @Test func keepsARipThatTheAlbumFolderOverlaps() throws {
        let (folder, _) = try makeRip()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let disc = try RippedDisc(folder: folder)
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        for album in [folder, folder.appending(path: "Album"), folder.deletingLastPathComponent()] {
            #expect(try !disc.deleteRipFiles(albumFolder: album))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == before)
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

    /// *The 1968 Demos*: three tracks that no repair could prove, which the user listened to
    /// and accepted. The rip is encoded as a verified one is, can go once encoded, and its
    /// reports say it was accepted.
    @Test func encodesARipAcceptedAsItIs() throws {
        let (folder, library) = try makeRip(verified: false)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let report = folder.appending(path: "disc.json")
        try Data().write(to: folder.appending(path: "Rip Report.md"))
        #expect(try !RippedDisc(folder: folder).isFinished && RipReport.read(from: report).advice != nil)
        try RipReport.accept(reportAt: report, date: Date(timeIntervalSince1970: 1_800_000_000.7))
        let accepted = try RipReport.read(from: report)
        #expect(accepted.accepted == Date(timeIntervalSince1970: 1_800_000_000) && !accepted.isVerified)
        #expect(accepted.unverifiedTracks == [2] && accepted.advice == nil)
        let markdown = try String(contentsOf: folder.appending(path: "Rip Report.md"), encoding: .utf8)
        #expect(
            markdown.contains("Accepted as-is 2027-01-15T08:00:00Z") && markdown.contains("track 2 is not verified"))
        let disc = try RippedDisc(folder: folder)
        #expect(disc.isAccepted && disc.isFinished)
        let files = try DiscEncoder(format: .flac).encode(disc, into: library)
        #expect(files.count == 2)
        let album = try RipReport.read(
            from: files[0].deletingLastPathComponent().appending(path: "Rip Report (Disc 2).json"))
        #expect(album.accepted != nil)
    }
}

extension EncodingTests {
    /// A solid-colour PNG of the given size, a real image that the cover scaler can decode.
    static func png(width: Int, height: Int, gray: CGFloat) -> CoverImage {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor(white: gray, alpha: 1).setFill()
            rect.fill()
            return true
        }
        let tiff = image.tiffRepresentation!
        return CoverImage(data: NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!)
    }

    /// A new cover after the rip goes into the rip's folder, the album's, the tags of every
    /// encoded file (the other tags kept), and the store for the release; the archive's
    /// cover put back is not kept for the release.
    @Test func retagsAnEncodedAlbumWithANewCover() throws {
        let (folder, library) = try makeRip()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let disc = try RippedDisc(folder: folder)
        let files = try DiscEncoder(format: .flac).encode(disc, into: library)
        let album = files[0].deletingLastPathComponent()
        let before = try FLACTags.read(files[0])
        let store = ReleaseCoverStore(folder: folder.deletingLastPathComponent().appending(path: "covers"))
        let cover = Self.png(width: 300, height: 300, gray: 0.5)
        var encoder = DiscEncoder(format: .flac)
        encoder.replayGain = true
        // The store under test is not the default one, so the kept cover is checked by hand.
        // The rip's disc.json has no encoding record (the encoder was called directly), so the
        // album folder is found through the library, as for a rip encoded from the terminal.
        let written = try encoder.retag(
            reportAt: folder.appending(path: "disc.json"), cover: cover, remember: false, library: library)
        #expect(written == files)
        #expect(try Data(contentsOf: folder.appending(path: "cover.png")) == cover.data)
        #expect(try Data(contentsOf: album.appending(path: "cover.png")) == cover.data)
        #expect(!FileManager.default.fileExists(atPath: album.appending(path: "cover.jpg").path))
        let embedded = try #require(try FLACTags.readFrontCover(files[0]))
        #expect(CoverImage(data: embedded).fileExtension == "png")
        // Every tag is as it was: the names, the credits, and the ReplayGain values.
        let after = try FLACTags.read(files[0])
        #expect(after.map { "\($0.key)=\($0.value)" } == before.map { "\($0.key)=\($0.value)" })
        try store.remember(cover, forReleaseID: "rel-1")
        #expect(store.cover(forReleaseID: "rel-1") == cover)
        try store.remember(Self.png(width: 10, height: 10, gray: 0.2), forReleaseID: "rel-1")
        #expect(store.cover(forReleaseID: "rel-1")?.data.count ?? 0 < cover.data.count)
        try store.forget(releaseID: "rel-1")
        #expect(store.cover(forReleaseID: "rel-1") == nil)
    }

    /// A library update after the album was renamed: the folder moves, the tags and the CUE
    /// sheet say the new name, the album report follows with its record, and the rip's
    /// disc.json keeps the merged edits.
    @Test func updatesTheLibraryAfterTheAlbumIsRenamed() throws {
        let (folder, library) = try makeRip()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let disc = try RippedDisc(folder: folder)
        let files = try DiscEncoder(format: .flac).encode(disc, into: library)
        let oldAlbum = files[0].deletingLastPathComponent()
        let releaseID = try #require(disc.release?.id)
        let edits = ReleaseEditsStore(url: folder.deletingLastPathComponent().appending(path: "edits.json"))
        try edits.remember(MetadataEdits(album: "Giants Stadium 1991"), forReleaseID: releaseID)
        let update = try DiscEncoder(format: .flac).updateLibrary(
            reportAt: folder.appending(path: "disc.json"), library: library, editsStore: edits,
            coverStore: ReleaseCoverStore(folder: folder.deletingLastPathComponent().appending(path: "covers")))
        let newAlbum = library.appending(path: "Grateful Dead/Giants Stadium 1991")
        #expect(update.albumFolder?.standardizedFileURL == newAlbum.standardizedFileURL && update.renamed == 1)
        #expect(!FileManager.default.fileExists(atPath: oldAlbum.path))
        #expect(update.files.map(\.lastPathComponent) == files.map(\.lastPathComponent))
        let tags = Dictionary(
            try FLACTags.read(update.files[0]).map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(tags["ALBUM"] == "Giants Stadium 1991" && tags["TITLE"] == "Help on the Way >")
        #expect(tags["REPLAYGAIN_TRACK_GAIN"] != nil)
        let contents = try FileManager.default.contentsOfDirectory(atPath: newAlbum.path)
        #expect(
            contents.contains("Giants Stadium 1991 (Disc 2).cue")
                && !contents.contains { $0.hasPrefix("Saint") && $0.hasSuffix(".cue") })
        let saved = try RipReport.read(from: newAlbum.appending(path: "Rip Report (Disc 2).json"))
        #expect(saved.encoding?.folder == newAlbum.path)
        #expect(MetadataEdits.read(fromDiscJSONOf: folder)?.album == "Giants Stadium 1991")
        // A second update changes nothing.
        let again = try DiscEncoder(format: .flac).updateLibrary(
            reportAt: folder.appending(path: "disc.json"), library: library, editsStore: edits,
            coverStore: ReleaseCoverStore(folder: folder.deletingLastPathComponent().appending(path: "covers")))
        #expect(again.renamed == 0 && again.files == update.files)
    }

    /// *American Beauty*: the deluxe edition's disc 1 and the single-disc edition, encoded into
    /// one album folder while they had one name. Renaming this rip's album moves its files only:
    /// the other edition keeps its folder, report, files, CUE sheet, and cover.
    @Test func renamesOneEditionOutOfAFolderAnotherShares() throws {
        let (folder, library) = try makeRip()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let disc = try RippedDisc(folder: folder)
        let files = try DiscEncoder(format: .flac).encode(disc, into: library)
        let oldAlbum = files[0].deletingLastPathComponent()
        let releaseID = try #require(disc.release?.id)
        // The other edition: a report of another release, its file, and its CUE sheet.
        var other = try RipReport.read(from: oldAlbum.appending(path: "Rip Report (Disc 2).json"))
        other.release?.id = "other-edition"
        // It shares this rip's first file, which must stay for it.
        other.encoding?.files = [
            .init(track: 1, file: "01-01 Other.flac"), .init(track: 2, file: files[0].lastPathComponent),
        ]
        try other.write(to: oldAlbum.appending(path: "Rip Report (Disc 1).json"))
        try Data("x".utf8).write(to: oldAlbum.appending(path: "01-01 Other.flac"))
        try Data("FILE \"01-01 Other.flac\" WAVE\n".utf8).write(to: oldAlbum.appending(path: "Other (Disc 1).cue"))
        try makeJPEG(width: 10, height: 10).write(to: oldAlbum)

        let edits = ReleaseEditsStore(url: folder.deletingLastPathComponent().appending(path: "edits.json"))
        try edits.remember(MetadataEdits(album: "Giants Stadium 1991"), forReleaseID: releaseID)
        let update = try DiscEncoder(format: .flac).updateLibrary(
            reportAt: folder.appending(path: "disc.json"), library: library, editsStore: edits,
            coverStore: ReleaseCoverStore(folder: folder.deletingLastPathComponent().appending(path: "covers")))
        let newAlbum = library.appending(path: "Grateful Dead/Giants Stadium 1991")
        #expect(update.albumFolder?.standardizedFileURL == newAlbum.standardizedFileURL)
        let moved = try FileManager.default.contentsOfDirectory(atPath: newAlbum.path)
        let stayed = try FileManager.default.contentsOfDirectory(atPath: oldAlbum.path)
        #expect(Set(moved).isSuperset(of: files.map(\.lastPathComponent)))
        #expect(moved.contains("Rip Report (Disc 2).json") && moved.contains("Giants Stadium 1991 (Disc 2).cue"))
        #expect(moved.contains("cover.jpg") && stayed.contains("cover.jpg"))
        #expect(
            Set(stayed).isSuperset(of: ["Rip Report (Disc 1).json", "01-01 Other.flac", "Other (Disc 1).cue"]))
        #expect(Set(stayed.filter { $0.hasSuffix(".flac") }) == ["01-01 Other.flac", files[0].lastPathComponent])
        #expect(!stayed.contains("Rip Report (Disc 2).json") && stayed.filter { $0.hasSuffix(".cue") }.count == 1)
    }

    /// The album of a multi-disc release is the whole release: until every disc is encoded,
    /// each disc's album gain is its own; the last disc takes the gain over every disc, and
    /// the discs encoded before it are written again with it.
    @Test func gainsTheAlbumOverEveryDiscOfASet() throws {
        let (folder2, library) = try makeRip()
        let root = folder2.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let (folder1, _) = try makeRip(disc1: true)
        defer { try? FileManager.default.removeItem(at: folder1.deletingLastPathComponent()) }
        let encoder = DiscEncoder(format: .flac)
        let (files2, record2) = try encoder.encodeWithRecord(try RippedDisc(folder: folder2), into: library)
        let gain2 = try #require(record2?.replayGain)
        #expect(gain2.release == nil && gain2.histogram != nil)
        func albumGain(_ file: URL) throws -> String? {
            try FLACTags.read(file).first { $0.key == "REPLAYGAIN_ALBUM_GAIN" }?.value
        }
        #expect(try albumGain(files2[0]) == gain2.album?.gainText)
        // The set view says that the whole set's gain waits for disc 1.
        let release = try #require(try RippedDisc(folder: folder2).release)
        let albumFolder = files2[0].deletingLastPathComponent()
        let waiting = try #require(RipSet.replayGain(of: release, folders: [root, albumFolder]))
        #expect(waiting.whole == nil && waiting.discs.count == 1)
        #expect(waiting.text.hasPrefix("Each disc has its own album gain until all 2 are encoded (1 so far): disc 2 "))

        let (files1, record1) = try encoder.encodeWithRecord(try RippedDisc(folder: folder1), into: library)
        let gain1 = try #require(record1?.replayGain)
        let whole = try #require(gain1.release)
        #expect(
            gain1.releaseDiscs == 2 && files1[0].deletingLastPathComponent() == files2[0].deletingLastPathComponent())
        // Disc 1 is quieter, so the whole album lies between the two discs.
        let (quiet, loud) = (try #require(gain1.album).loudness, try #require(gain2.album).loudness)
        #expect(quiet < whole.loudness && whole.loudness < loud)
        #expect(try albumGain(files1[0]) == whole.gainText && albumGain(files2[1]) == whole.gainText)
        let album = files1[0].deletingLastPathComponent()
        let saved2 = try RipReport.read(from: album.appending(path: "Rip Report (Disc 2).json"))
        #expect(saved2.encoding?.replayGain?.release == whole && saved2.encoding?.replayGain?.album == gain2.album)
        let markdown = try String(contentsOf: album.appending(path: "Rip Report (Disc 2).md"), encoding: .utf8)
        #expect(markdown.contains("the album, all 2 discs, is \(whole.loudnessText)"))
        let done = try #require(RipSet.replayGain(of: release, folders: [album]))
        #expect(done.whole == whole && done.discs.count == 2)
        #expect(done.text.hasPrefix("Album gain over all 2 discs: \(whole.gainText), peak "))
        #expect(done.text.contains("On its own, disc 1 \(try #require(gain1.album).gainText) and disc 2 "))

        // A record from before histograms were kept is measured from its files.
        var old = try #require(saved2.encoding)
        old.replayGain?.histogram = nil
        old.replayGain?.release = nil
        try old.save(inReportAt: album.appending(path: "Rip Report (Disc 2).json"))
        let again = DiscEncoder.releaseGain(
            of: try #require(saved2.release), in: album, disc: (1, try #require(gain1.histogram)))
        #expect(abs((again?.values.loudness ?? 0) - whole.loudness) < 0.01 && again?.discs == 2)
        let measured = try RipReport.read(from: album.appending(path: "Rip Report (Disc 2).json"))
        #expect(measured.encoding?.replayGain?.histogram == gain2.histogram)
    }

    /// A track's title changed after the encoding, in the album folder's report (the rip's
    /// files are gone): the library update renames that track's file and writes its tags,
    /// and leaves the other file as it was.
    @Test func renamesOneTrackAfterTheRip() throws {
        let (folder, library) = try makeRip()
        let root = folder.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try DiscEncoder(format: .flac).encode(try RippedDisc(folder: folder), into: library)
        let album = files[0].deletingLastPathComponent()
        let report = album.appending(path: "Rip Report (Disc 2).json")
        func inode(_ file: URL) throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        }
        let before = try inode(files[1])
        try MetadataEdits(tracks: [1: .init(title: "Help on the Way (Live)")]).save(inReportAt: report)
        let store = ReleaseEditsStore(url: root.appending(path: "edits.json"))
        let release = try #require(try RipReport.read(from: report).release)
        #expect(MetadataEdits.current(forReportAt: report, release: release, store: store).tracks[1]?.title != nil)
        let update = try DiscEncoder(format: .flac).updateLibrary(
            reportAt: report, library: library, editsStore: store,
            coverStore: ReleaseCoverStore(folder: root.appending(path: "covers")))
        #expect(update.renamed == 1)
        #expect(update.files.map(\.lastPathComponent) == ["02-01 Help on the Way (Live).flac", "02-02 Slipknot!.flac"])
        #expect(
            try FLACTags.read(update.files[0]).contains { $0.key == "TITLE" && $0.value == "Help on the Way (Live)" })
        #expect(try inode(update.files[1]) == before)
        let saved = try RipReport.read(from: report)
        #expect(saved.encoding?.file(ofTrack: 1) == "02-01 Help on the Way (Live).flac")
    }

    /// Change Release: disc 2 of a 2-disc release becomes a 1-disc edition with other names.
    /// The files, the album folder, the CUE sheet, and the album's report take the new names;
    /// the rip's own edits go, and the choice is kept for the disc.
    @Test func changesTheReleaseOfAnEncodedRip() throws {
        let (folder, library) = try makeRip()
        let root = folder.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try DiscEncoder(format: .flac).encode(try RippedDisc(folder: folder), into: library)
        let oldAlbum = files[0].deletingLastPathComponent()
        let discJSON = folder.appending(path: "disc.json")
        try MetadataEdits(tracks: [1: .init(title: "Help on the Way (Live)")]).save(inReportAt: discJSON)
        let toc = try TOC(ctdbTOCString: try RipReport.read(from: discJSON).toc)
        var single = try #require(try RipReport.read(from: discJSON).release)
        single.id = "single"
        single.title = "Giants Stadium 1991"
        single.barcode = "081227900000"
        single.media = [single.media[1]]
        single.media[0].position = 1
        single.media[0].discIDs = [toc.musicBrainzDiscID]
        let choices = ReleaseChoiceStore(url: root.appending(path: "choices.json"))

        let update = try DiscEncoder(format: .flac).changeRelease(
            reportAt: discJSON, to: single, library: library,
            editsStore: ReleaseEditsStore(url: root.appending(path: "edits.json")),
            coverStore: ReleaseCoverStore(folder: root.appending(path: "covers")), choiceStore: choices)
        let album = library.appending(path: "Grateful Dead/Giants Stadium 1991")
        #expect(update.albumFolder?.standardizedFileURL == album.standardizedFileURL)
        #expect(update.report == discJSON && !FileManager.default.fileExists(atPath: oldAlbum.path))
        let contents = Set(try FileManager.default.contentsOfDirectory(atPath: album.path))
        #expect(contents.isSuperset(of: ["Rip Report.json", "Rip Report.md", "Giants Stadium 1991.cue", "cover.jpg"]))
        #expect(!contents.contains { $0.contains("(Disc 2)") })
        #expect(update.files.map(\.lastPathComponent) == ["01 Help on the Way.flac", "02 Slipknot!.flac"])
        let tags = try FLACTags.read(update.files[0])
        #expect(tags.contains { $0.key == "MUSICBRAINZ_ALBUMID" && $0.value == "single" })
        #expect(tags.contains { $0.key == "ALBUM" && $0.value == "Giants Stadium 1991" })
        #expect(tags.contains { $0.key == "TITLE" && $0.value == "Help on the Way >" })
        #expect(
            try RipReport.read(from: discJSON).release?.id == "single"
                && MetadataEdits.read(fromDiscJSONOf: folder) == nil)
        let albumReport = try RipReport.read(from: album.appending(path: "Rip Report.json"))
        #expect(albumReport.release?.id == "single" && albumReport.encoding?.folder == album.path)
        #expect(choices.choices(forDiscID: toc.musicBrainzDiscID) == ["single"])
    }

    /// No disc of the release has the rip's TOC: nothing changes.
    @Test func refusesAReleaseWithoutTheDisc() throws {
        let (folder, library) = try makeRip()
        let root = folder.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let discJSON = folder.appending(path: "disc.json")
        var other = try #require(try RipReport.read(from: discJSON).release)
        other.id = "other"
        other.media = [other.media[0]]
        let before = try Data(contentsOf: discJSON)
        #expect(throws: EncodingError.self) {
            try DiscEncoder(format: .flac).changeRelease(
                reportAt: discJSON, to: other, library: library,
                choiceStore: ReleaseChoiceStore(url: root.appending(path: "choices.json")))
        }
        #expect(try Data(contentsOf: discJSON) == before)
    }

    /// *Let It Be… Naked*: disc 1 tagged as the Japanese edition, disc 2 as the US one, in one
    /// album folder. Disc 1's report in the library changes to the US edition: it stays where it
    /// is, its CUE sheet is written again, and its album gain is now over both discs.
    @Test func changesOneDiscOfASetToTheOtherDiscsEdition() throws {
        let (folder2, library) = try makeRip()
        let root = folder2.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let (folder1, _) = try makeRip(disc1: true)
        defer { try? FileManager.default.removeItem(at: folder1.deletingLastPathComponent()) }
        try RipReport.update(reportAt: folder1.appending(path: "disc.json")) { $0.release?.id = "japan" }
        let encoder = DiscEncoder(format: .flac)
        let files2 = try encoder.encode(try RippedDisc(folder: folder2), into: library)
        let files1 = try encoder.encode(try RippedDisc(folder: folder1), into: library)
        let album = files2[0].deletingLastPathComponent()
        #expect(files1[0].deletingLastPathComponent() == album)
        let report1 = album.appending(path: "Rip Report (Disc 1).json")
        #expect(try RipReport.read(from: report1).encoding?.replayGain?.release == nil)
        let release = try #require(try RipReport.read(from: folder2.appending(path: "disc.json")).release)

        let update = try encoder.changeRelease(
            reportAt: report1, to: release, library: library,
            editsStore: ReleaseEditsStore(url: root.appending(path: "edits.json")),
            coverStore: ReleaseCoverStore(folder: root.appending(path: "covers")),
            choiceStore: ReleaseChoiceStore(url: root.appending(path: "choices.json")))
        #expect(update.report == report1 && update.albumFolder == album && update.renamed == 0)
        let saved = try RipReport.read(from: report1)
        #expect(saved.release?.id == "rel" && saved.encoding?.replayGain?.releaseDiscs == 2)
        let sheets = try FileManager.default.contentsOfDirectory(atPath: album.path).filter { $0.hasSuffix(".cue") }
        #expect(sheets.count == 2 && sheets.contains { $0.hasSuffix("(Disc 1).cue") })
        #expect(try FLACTags.read(files1[0]).contains { $0.key == "MUSICBRAINZ_ALBUMID" && $0.value == "rel" })
    }
}
