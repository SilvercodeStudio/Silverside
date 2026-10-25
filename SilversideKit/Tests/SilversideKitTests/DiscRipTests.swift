import Foundation
import Testing

@testable import SilversideKit

/// The events of a rip, in order, from whichever thread sends them.
final class DiscRipEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events = [DiscRipEvent]()

    func append(_ event: DiscRipEvent) {
        lock.withLock { events.append(event) }
    }

    var list: [DiscRipEvent] { lock.withLock { events } }
}

struct DiscRipTests {
    /// A rip of a simulated disc into a temporary folder, and the events it sent. Offline,
    /// unless `web` answers the lookups. With `hidesFirstTrack`, the first of `trackSectors`
    /// is audio before track 1. `prepare` can damage the drive.
    func rip(
        trackSectors: [Int] = [800, 900], hidesFirstTrack: Bool = false, tracks: [Int]? = nil, web: FakeWeb? = nil,
        cover: CoverImage? = nil, coverStore: ReleaseCoverStore? = nil, prepare: (SimulatedDrive) -> Void = { _ in },
        configure: (inout DiscRipOptions) -> Void = { _ in }
    ) async throws -> (DiscRipResult, [DiscRipEvent], samples: [UInt32], root: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var (toc, samples) = try makeDisc(trackSectors: trackSectors)
        if hidesFirstTrack {
            toc = try TOC(audioTrackStarts: toc.audioTracks.dropFirst().map(\.startLBA), leadOutLBA: toc.leadOutLBA)
        }
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: 6)
        drive.isrcs = [1: "USRC17607839"]
        prepare(drive)
        var settings = Settings()
        settings.rips = root.path
        var options = DiscRipOptions(settings: settings)
        options.offline = web == nil
        options.tracks = tracks
        options.cover = cover
        configure(&options)
        let profiles = try DriveProfileStore(url: root.appending(path: "DriveProfiles.json"))
        var rip = DiscRip(
            drive: drive, identity: DriveIdentity(vendor: "SIM", product: "DRIVE", revision: "1.0"),
            settings: settings, options: options, profiles: profiles)
        if let web { rip.webClient = await web.client(in: root.appending(path: "cache")) }
        if let coverStore { rip.coverStore = coverStore }
        // The offset comes from the options, since the drive is not in AccurateRip's list.
        rip.options.readOffset = 6
        let events = DiscRipEvents()
        rip.events = { events.append($0) }
        return (try await rip.run(), events.list, samples, root)
    }

    /// A stop from an event (the app's Stop button) ends the rip after the read under way,
    /// and the folder keeps the tracks written so far. So does cancelling the task.
    @Test(arguments: [false, true])
    func stopsWhenAsked(byCancellingTheTask: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (toc, samples) = try makeDisc(trackSectors: [800, 900])
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: 6)
        var settings = Settings()
        settings.rips = root.path
        var options = DiscRipOptions(settings: settings)
        options.offline = true
        options.readOffset = 6
        var rip = DiscRip(
            drive: drive, identity: DriveIdentity(vendor: "SIM", product: "DRIVE", revision: "1.0"),
            settings: settings, options: options,
            profiles: try DriveProfileStore(url: root.appending(path: "DriveProfiles.json")))
        let events = DiscRipEvents()
        let stop = rip.stop
        rip.events = { event in
            events.append(event)
            if case .trackFinished(let report, _, _) = event, report.number == 1, !byCancellingTheTask {
                stop.stop()
            }
        }
        let task = Task { [rip] in try await rip.run() }
        if byCancellingTheTask {
            // After the first track's file is there.
            let folder = root.appending(path: "Silverside \(toc.musicBrainzDiscID)")
            let deadline = ContinuousClock.now + .seconds(60)
            while !FileManager.default.fileExists(atPath: folder.appending(path: "Track 01.wav").path) {
                // A wrong folder name fails the test instead of hanging it.
                try #require(ContinuousClock.now < deadline, "Track 01.wav never appeared in \(folder.path)")
                try await Task.sleep(for: .milliseconds(5))
            }
            task.cancel()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let folder = root.appending(path: "Silverside \(toc.musicBrainzDiscID)")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "Track 01.wav").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Track 02.wav").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: RipFolder.claimFile).path))
        #expect(!events.list.contains { if case .finished = $0 { true } else { false } })
    }

    /// The AccurateRip database file for a disc, from its true samples: v2 checksums, confidence 7.
    static func accurateRipFile(toc: TOC, samples: [UInt32]) -> Data {
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let id = toc.accurateRipDiscID
        data.append(UInt8(id.audioTrackCount))
        append32(id.id1)
        append32(id.id2)
        append32(id.freedbID)
        let audio = toc.audioTracks
        for (index, track) in audio.enumerated() {
            let sectors = toc.sectorRange(of: track)
            let trackSamples = Array(samples[(sectors.lowerBound * 588)..<(sectors.upperBound * 588)])
            let checksum = AccurateRipAccumulator.checksum(
                of: trackSamples[...], isFirstTrack: index == 0, isLastTrack: index == audio.count - 1)
            let sector450 = Array(trackSamples[(450 * 588)..<(451 * 588)])
            let frame450 = AccurateRipAccumulator.checksum(of: sector450[...], isFirstTrack: false, isLastTrack: false)
            data.append(7)
            append32(checksum.v2)
            append32(frame450.v1)
        }
        return data
    }

    /// A CTDB lookup answer with one entry for the disc's true samples, 8 syndromes for each
    /// column, and its repair data as `p.cuetools.net` serves it.
    static func ctdbAnswer(toc: TOC, samples: [UInt32]) -> (lookup: Data, repairData: Data) {
        let layout = CTDBLayout(toc: toc)
        let first = toc.audioTracks[0].startLBA * 588
        let audio = Array(samples[first..<(toc.audioLeadOutLBA * 588)])
        let syndromes = CTDB.syndromes(of: audio, layout: layout, shift: 0, count: 8)
        var column0 = Data()
        for value in syndromes[0..<8] { withUnsafeBytes(of: value.littleEndian) { column0.append(contentsOf: $0) } }
        let crcs = CTDB.trackCRCs(of: audio, toc: toc, layout: layout).map { String(format: "%08x", $0) }
        let xml = """
            <ctdb><entry confidence="5" crc32="\(String(format: "%08x", CTDB.discCRC(of: audio, layout: layout)))" \
            hasparity="http://p.cuetools.net/1" id="1" npar="8" stride="5880" \
            syndrome="\(column0.base64EncodedString())" toc="\(toc.ctdbTOCString)" \
            trackcrcs="\(crcs.joined(separator: " "))" /></ctdb>
            """
        var repairData = Data(count: 2 * CTDBLayout.stride * 8)
        for column in 0..<CTDBLayout.stride {
            for i in 0..<8 {
                let value = syndromes[column * 8 + i]
                repairData[2 * (i * CTDBLayout.stride + column)] = UInt8(value & 0xFF)
                repairData[2 * (i * CTDBLayout.stride + column) + 1] = UInt8(value >> 8)
            }
        }
        return (Data(xml.utf8), repairData)
    }

    /// A web with the disc in AccurateRip and CTDB, and not in MusicBrainz.
    static func web(toc: TOC, samples: [UInt32]) -> FakeWeb {
        let ctdb = ctdbAnswer(toc: toc, samples: samples)
        return FakeWeb([
            (toc.accurateRipDiscID.databaseURL.absoluteString, accurateRipFile(toc: toc, samples: samples)),
            ("http://db.cuetools.net/lookup2.php", ctdb.lookup),
            ("http://p.cuetools.net/1", ctdb.repairData),
        ])
    }

    /// A second rip of a disc that is already in the library asks before it replaces the
    /// files: no keeps them and the rip, and yes encodes over them.
    @Test func asksBeforeReplacingFilesInTheLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (toc, samples) = try makeDisc(trackSectors: [800, 900])
        var settings = Settings()
        settings.rips = root.appending(path: "rips").path
        settings.keepRipAfterEncoding = true
        let library = root.appending(path: "library")
        let asked = DiscRipEvents()

        func rip(replaces: Bool?) async throws -> (DiscRipResult, [DiscRipEvent]) {
            var options = DiscRipOptions(settings: settings)
            options.offline = true
            options.readOffset = 6
            options.manualRelease = .manual(toc: toc)
            var rip = DiscRip(
                drive: SimulatedDrive(toc: toc, samples: samples, readOffset: 6),
                identity: DriveIdentity(vendor: "SIM", product: "DRIVE", revision: "1.0"), settings: settings,
                options: options, profiles: try DriveProfileStore(url: root.appending(path: "DriveProfiles.json")))
            var encoder = DiscEncoder(format: .wav)
            encoder.allowsUnverified = true
            rip.encoder = encoder
            rip.library = library
            if let replaces {
                rip.confirmOverwrite = { existing in
                    asked.append(.encodingDeclined(existing))
                    return replaces
                }
            }
            let events = DiscRipEvents()
            rip.events = { events.append($0) }
            return (try await rip.run(), events.list)
        }

        let (first, firstEvents) = try await rip(replaces: false)
        #expect(first.encodedFiles.count == 2 && asked.list.isEmpty)
        // The kept rip's report says where its tracks went.
        let kept = try RipReport.read(from: first.folder.appending(path: "disc.json"))
        #expect(kept.encoding?.format == .wav && kept.encoding?.files.count == 2)
        #expect(firstEvents.filter { if case .trackEncoded = $0 { true } else { false } }.count == 2)

        let (declined, declinedEvents) = try await rip(replaces: false)
        #expect(asked.list.count == 1 && declined.encodedFiles.isEmpty && !declined.deletedRip)
        #expect(
            declinedEvents.contains { if case .encodingDeclined(let files) = $0 { files.count == 2 } else { false } })
        #expect(!declinedEvents.contains { if case .encoding = $0 { true } else { false } })

        let (replaced, _) = try await rip(replaces: true)
        #expect(asked.list.count == 2 && replaced.encodedFiles == first.encodedFiles)

        // With no one to ask, the encoding stops as before.
        await #expect(throws: EncodingError.exists(first.encodedFiles[0])) { try await rip(replaces: nil) }
    }

    @Test func verifiesWithAccurateRipAndCTDB() async throws {
        let (toc, samples) = try makeDisc(trackSectors: [800, 900])
        let web = Self.web(toc: toc, samples: samples)
        let (result, events, _, root) = try await rip(web: web)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(result.report.tracks.map(\.accurateRip) == [.accurate, .accurate])
        #expect(result.report.tracks.map(\.accurateRipConfidence) == [[0, 7], [0, 7]])
        #expect(result.report.ctdb.status == .verified && result.report.ctdb.entry == 1)
        #expect(result.report.tracks.map(\.ctdbConfidence) == [5, 5])
        #expect(result.report.isVerified)
        let lookups = events.compactMap { event -> String? in
            if case .lookups(let records, let ctdb) = event { return "\(records ?? -1) \(ctdb?.entries ?? -1)" }
            return nil
        }
        #expect(lookups == ["1 1"])
        // The repair data was not needed.
        #expect(await !web.requests.contains { $0.hasPrefix("http://p.cuetools.net") })
        // The rip confirmed the drive's offset on this disc.
        if case .finished(_, let offsets, let profile) = events.last {
            #expect(offsets == [6] && profile.observations.count == 1)
        } else {
            Issue.record("No finished event")
        }
    }

    /// A sector that reads wrong every time: the secure rip cannot see it, CTDB repairs it,
    /// and the track is written again and matches AccurateRip.
    @Test func repairsWithCTDBAndWritesTheTrackAgain() async throws {
        let (toc, samples) = try makeDisc(trackSectors: [800, 900])
        let (result, events, _, root) = try await rip(web: Self.web(toc: toc, samples: samples)) {
            $0.corruptSectors = [1000]
        }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(result.report.ctdb.status == .repaired)
        #expect(result.report.tracks.map(\.accurateRip) == [.accurate, .accurate])
        #expect(result.report.tracks[1].repairedSamples == 588)
        #expect(events.contains { if case .trackRepaired(2, 588, .accurate) = $0 { true } else { false } })
        // Without overread, the disc's last 6 samples (the drive's offset) are silence; CTDB
        // leaves out the last row, and AccurateRip the last 2940 samples, so both still match.
        let written = try WAVFile.read(result.folder.appending(path: "Track 02.wav"))
        #expect(written.dropLast(6) == samples[(800 * 588)...].dropLast(6))
        // A repaired track keeps no suspects.
        #expect(!FileManager.default.fileExists(atPath: result.folder.appending(path: "Track 02.suspects").path))
        #expect(result.report.files?.contains("Track 02.suspects") == false)
    }

    /// With no network, every lookup fails, and the rip goes on as not checked.
    @Test func goesOnWhenTheLookupsFail() async throws {
        let (result, events, _, root) = try await rip(web: FakeWeb(failsEverything: true))
        defer { try? FileManager.default.removeItem(at: root) }
        let failed = events.compactMap { event -> DiscRipEvent.Lookup? in
            if case .lookupFailed(let lookup, _) = event { return lookup }
            return nil
        }
        #expect(failed == [.accurateRip, .ctdb])
        #expect(events.contains { if case .releaseLookupFailed = $0 { true } else { false } })
        #expect(events.contains { if case .lookups(nil, nil) = $0 { true } else { false } })
        #expect(result.report.tracks.map(\.accurateRip) == [.notInDatabase, .notInDatabase])
        #expect(result.report.ctdb.status == .notChecked)
        #expect(FileManager.default.fileExists(atPath: result.folder.appending(path: "Track 02.wav").path))
    }

    @Test func ripsEveryTrackIntoAFolderNamedFromTheDiscID() async throws {
        let (result, events, samples, root) = try await rip()
        defer { try? FileManager.default.removeItem(at: root) }
        let toc = try TOC(ctdbTOCString: result.report.toc)
        #expect(result.folder.lastPathComponent == "Silverside \(toc.musicBrainzDiscID)")
        #expect(result.report.tracks.map(\.number) == [1, 2])
        #expect(result.report.tracks[0].isrc == "USRC17607839")
        // The offset-corrected audio, as the WAV files hold it.
        let track1 = try WAVFile.read(result.folder.appending(path: "Track 01.wav"))
        #expect(track1 == Array(samples[0..<(800 * CDDA.samplesPerSector)]))
        for name in ["Track 02.wav", "disc.json", "Rip Report.md"] {
            #expect(FileManager.default.fileExists(atPath: result.folder.appending(path: name).path))
        }
        // The claim on the folder ends with the rip, and the report lists what the rip wrote.
        #expect(!FileManager.default.fileExists(atPath: result.folder.appending(path: RipFolder.claimFile).path))
        #expect(result.report.files == ["Rip Report.md", "Track 01.wav", "Track 02.wav", "disc.json"])

        // The steps, in order.
        let steps = events.compactMap { event -> String? in
            switch event {
            case .disc: "disc"
            case .drive(_, let offset, let source): "drive \(offset) \(source)"
            case .release(nil): "no release"
            case .folder: "folder"
            case .trackStarted(let track, let position, let count): "start \(track.number) \(position)/\(count)"
            case .trackFinished(let report, _, _): "finish \(report.number)"
            case .finished: "finished"
            default: nil
            }
        }
        #expect(
            steps == [
                "disc", "drive 6 --offset", "no release", "folder", "start 1 1/2", "finish 1", "start 2 2/2",
                "finish 2", "finished",
            ])
        #expect(events.contains { if case .reading = $0 { true } else { false } })
    }

    @Test func ripsOnlyTheChosenTracks() async throws {
        let (result, _, _, root) = try await rip(tracks: [2])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(result.report.tracks.map(\.number) == [2])
        #expect(!FileManager.default.fileExists(atPath: result.folder.appending(path: "Track 01.wav").path))
    }

    @Test func rejectsTracksThatTheDiscDoesNotHave() async throws {
        await #expect(throws: DiscRipError.noSuchTracks([3])) { _ = try await rip(tracks: [2, 3]) }
    }

    @Test func keepsTheAudioBeforeTrackOne() async throws {
        // Track 1 starts at sector 300; the audio before it is not silence.
        let (result, events, samples, root) = try await rip(trackSectors: [300, 800, 900], hidesFirstTrack: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hidden = try #require(result.report.hiddenTrack)
        #expect(hidden.sectors == 300)
        #expect(events.contains { if case .hiddenTrack = $0 { true } else { false } })
        let audio = try WAVFile.read(result.folder.appending(path: "Track 00.wav"))
        #expect(audio == Array(samples[0..<(300 * CDDA.samplesPerSector)]))
    }

    /// A cover the user gives is the rip's cover, even offline and with no release.
    @Test func savesTheCoverTheUserGives() async throws {
        let png = CoverImage(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]))
        let (result, events, _, root) = try await rip(cover: png)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = result.folder.appending(path: "cover.png")
        #expect(try Data(contentsOf: file) == png.data)
        #expect(result.report.files?.contains("cover.png") == true)
        #expect(events.contains { if case .artwork(.saved([file])) = $0 { true } else { false } })
    }

    /// A box set whose discs take their own sleeves: the rip saves the set's cover (the
    /// archive's main front) and, beside it, the sleeve whose comment names this disc.
    @Test func savesTheDiscsOwnSleeve() async throws {
        let front = CoverImage(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1]))
        let sleeve = CoverImage(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 2]))
        let listing = """
            {"images": [
              {"id": 1, "types": ["Front"], "front": true, "comment": "Outer box, front",
               "image": "http://coverartarchive.org/release/box/1.png"},
              {"id": 2, "types": ["Front"], "front": false, "comment": "Day one (Mediums 1–2)",
               "image": "http://coverartarchive.org/release/box/2.png"}
            ]}
            """
        let web = FakeWeb([
            ("https://coverartarchive.org/release/box/1.png", front.data),
            ("https://coverartarchive.org/release/box/2.png", sleeve.data),
            ("https://coverartarchive.org/release/box", Data(listing.utf8)),
        ])
        func medium(_ position: Int, tracks: Int) -> MusicBrainzRelease.Medium {
            .init(
                position: position, format: "CD", title: nil, discIDs: [],
                tracks: (1...tracks).map {
                    .init(
                        position: $0, number: String($0), title: "T\($0)", length: nil, artistCredit: [],
                        recordingID: nil)
                })
        }
        let release = MusicBrainzRelease(
            id: "box", title: "Box", artistCredit: [.init(name: "Band")], date: nil, country: nil, status: nil,
            barcode: nil, disambiguation: nil, labels: [], releaseGroup: nil,
            media: [medium(1, tracks: 3), medium(2, tracks: 2)], hasFrontCover: true)
        let store = ReleaseCoverStore(
            folder: FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: store.folder) }
        try store.useDiscSleeves(true, releaseID: "box")
        let (result, _, _, root) = try await rip(
            web: web, coverStore: store,
            configure: {
                $0.offline = true
                $0.release = release
            })
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try Data(contentsOf: result.folder.appending(path: "cover.png")) == front.data)
        #expect(try Data(contentsOf: result.folder.appending(path: "cover (Disc 2).png")) == sleeve.data)
        #expect(result.report.files?.contains("cover (Disc 2).png") == true)
        #expect(try RippedDisc(folder: result.folder).coverFile?.lastPathComponent == "cover (Disc 2).png")
        // The rule stays: nothing the rip did chose a cover for the whole set.
        #expect(store.usesDiscSleeves(releaseID: "box") && store.cover(forReleaseID: "box") == nil)
    }

    /// Every track's report has the CRC-32s that EAC and XLD print, and the disc's media type.
    /// With test and copy, a second read of each track follows the rip, and its CRC-32 is
    /// compared with the copy's.
    @Test func keepsChecksumsAndTestsEachTrack() async throws {
        let (result, events, samples, root) = try await rip(
            prepare: { $0.mediaType = .rewritable }, configure: { $0.testAndCopy = true })
        defer { try? FileManager.default.removeItem(at: root) }
        let tracks = result.report.tracks
        let first = Array(samples[0..<(800 * CDDA.samplesPerSector)])
        #expect(tracks[0].crc32 == CRC32.hex(CRC32.checksum(of: first[...])))
        #expect(tracks.map(\.testReadMatches) == [true, true])
        #expect(tracks.map(\.testCRC32) == tracks.map(\.crc32))
        #expect(result.report.media == .rewritable)
        let tested = events.compactMap { event -> Int? in
            if case .reading(.testing(let track, _)) = event { return track }
            return nil
        }
        #expect(Set(tested) == [1, 2])
        let summaries = events.compactMap { event -> String? in
            if case .trackFinished(_, let summary, _) = event { return summary }
            return nil
        }
        #expect(summaries.allSatisfy { $0.hasSuffix("test read matches") })
        #expect(result.report.markdown.contains("| Media | CD-RW |"))
    }

    /// Without test and copy (the default), there is no test read and no test CRC.
    @Test func doesNotTestByDefault() async throws {
        let (result, events, _, root) = try await rip()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(result.report.tracks.allSatisfy { $0.testCRC32 == nil && $0.crc32 != nil })
        #expect(!events.contains { if case .reading(.testing) = $0 { true } else { false } })
    }
}
