import Foundation
import Testing

@testable import SilversideKit

/// Switchfoot *Nothing Is Sound* (Sparrow/EMI SPD 44952, copy-controlled, ripped on the MATSHITA
/// 2026-11-13): 12 audio tracks, then a second session with a data track and a track 14 of 31
/// sectors, which the MATSHITA cannot read. The session gap ends track 12 as on an Enhanced CD.
struct CopyProtectedDiscTests {
    static let starts = [0, 16900, 36431, 58260, 81083, 101288, 125133, 144991, 160635, 176871, 189201, 210383]

    /// The TOC as the drive reads it, with its sessions.
    static func toc() throws -> TOC {
        let audio = starts.enumerated().map { TOC.Track(number: $0.offset + 1, startLBA: $0.element) }
        return try TOC(
            tracks: audio + [
                .init(number: 13, startLBA: 241204, kind: .data, session: 2),
                .init(number: 14, startLBA: 332819, session: 2),
            ], leadOutLBA: 332850)
    }

    @Test func endsTheAudioSessionBeforeTheSessionGap() throws {
        let toc = try Self.toc()
        #expect(toc.isEnhanced)
        #expect(toc.audioLeadOutLBA == 241204 - CDDA.sessionGapSectors)
        // Track 12 is 4:18.96, as AccurateRip has it (v2 4844169E, confidence 21), not 6:50.
        #expect(toc.sectorRange(of: toc.tracks[11]) == 210383..<229804)
        #expect(toc.sectorRange(of: toc.tracks[13]) == 332819..<332850)
        #expect(toc.audioAreas == [0..<229804])
        #expect(toc.sessionAudioTracks.map(\.number) == Array(1...12))
        // AccurateRip counts every audio track, track 14 too: the ID of the rip's records.
        #expect(toc.audioTracks.count == 13)
        #expect(toc.accurateRipDiscID.name == "dBAR-013-001e02fd-0134b6eb-c211560e")
    }

    @Test func leavesTheDataSessionOutOfTheMusicBrainzDiscID() throws {
        let toc = try Self.toc()
        // The same disc without track 14: an Enhanced CD as any other.
        let enhanced = try TOC(tracks: Array(toc.tracks.prefix(13)), leadOutLBA: 332819)
        #expect(toc.musicBrainzDiscID == enhanced.musicBrainzDiscID)
        #expect(toc.musicBrainzTOCString == enhanced.musicBrainzTOCString)
        #expect(toc.musicBrainzTOCString.hasPrefix("1+12+\(229804 + CDDA.leadInSectors)+"))
    }

    @Test func findsTheSessionsInTheReportsTOCString() throws {
        let toc = try Self.toc()
        #expect(toc.ctdbTOCString == Self.starts.map(String.init).joined(separator: ":") + ":-241204:332819:332850")
        #expect(try TOC(ctdbTOCString: toc.ctdbTOCString) == toc)
        // A data track too close to the audio for a session gap stays in the first session.
        let single = try TOC(ctdbTOCString: "0:1000:-1500:3000")
        #expect(!single.isEnhanced && single.tracks.allSatisfy { $0.session == 1 })
        #expect(single.sectorRange(of: single.tracks[1]) == 1000..<1500)
    }

    /// A release's disc of 12 tracks fits: the 31 sectors after the data track are no song.
    @Test func fitsAReleaseWithoutTheTrackAfterTheData() throws {
        let toc = try Self.toc()
        let lengths = toc.sessionAudioTracks.map { toc.sectorRange(of: $0).count * 1000 / CDDA.sectorsPerSecond }
        let medium = MusicBrainzRelease.Medium(
            position: 1, format: "CD", title: nil, discIDs: [],
            tracks: lengths.enumerated().map { index, length in
                .init(
                    position: index + 1, number: String(index + 1), title: "Song \(index + 1)", length: length,
                    artistCredit: [], recordingID: nil)
            })
        #expect(ReleaseRanking.fits(medium, toc: toc))
    }

    /// The drive reads track 12 to the session's end, and no further.
    @Test func readsTheLastAudioTrackOfTheFirstSession() throws {
        let toc = try TOC(
            tracks: [
                .init(number: 1, startLBA: 0),
                .init(number: 2, startLBA: 800),
                .init(number: 3, startLBA: 1700 + CDDA.sessionGapSectors, kind: .data, session: 2),
                .init(number: 4, startLBA: 1700 + CDDA.sessionGapSectors + 300, session: 2),
            ], leadOutLBA: 1700 + CDDA.sessionGapSectors + 331)
        var generator = SplitMix64(state: 5)
        var samples = (0..<(1700 * 588)).map { _ in UInt32.random(in: 1...UInt32.max, using: &generator) }
        samples += [UInt32](repeating: 0, count: toc.leadOutLBA * 588 - samples.count)
        let drive = SimulatedDrive(toc: toc, samples: samples)
        let reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
        let range = toc.sectorRange(of: toc.tracks[1])
        #expect(range == 800..<1700)
        let read = try reader.readSamples((range.lowerBound * 588)..<(range.upperBound * 588))
        #expect(read == Array(samples[(800 * 588)..<(1700 * 588)]))
    }

    /// A disc laid out as *Nothing Is Sound* is, small: audio tracks 1 and 2, then a second
    /// session with a data track 3 and an audio track 4 that a drive cannot read.
    static func smallDisc() throws -> (toc: TOC, samples: [UInt32]) {
        let data = 1700 + CDDA.sessionGapSectors
        let toc = try TOC(
            tracks: [
                .init(number: 1, startLBA: 0),
                .init(number: 2, startLBA: 800),
                .init(number: 3, startLBA: data, kind: .data, session: 2),
                // Longer than the real 31 sectors, so that AccurateRip's test file has its sector 450.
                .init(number: 4, startLBA: data + 300, session: 2),
            ], leadOutLBA: data + 300 + 600)
        var generator = SplitMix64(state: 7)
        var samples = (0..<(1700 * 588)).map { _ in UInt32.random(in: 1...UInt32.max, using: &generator) }
        samples += [UInt32](repeating: 0, count: toc.leadOutLBA * 588 - samples.count)
        return (toc, samples)
    }

    /// A rip of `smallDisc` with the disc in AccurateRip and CTDB; `tracks` as the options have them.
    func rip(tracks: [Int]?) async throws -> (DiscRipResult, root: URL) {
        let (toc, samples) = try Self.smallDisc()
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: 0)
        var settings = Settings()
        settings.rips = root.appending(path: "rips").path
        settings.dataTracks = .skip
        var options = DiscRipOptions(settings: settings)
        options.readOffset = 0
        options.tracks = tracks
        options.manualRelease = .manual(toc: toc)
        var rip = DiscRip(
            drive: drive, identity: DriveIdentity(vendor: "SIM", product: "DRIVE", revision: "1.0"),
            settings: settings, options: options,
            profiles: try DriveProfileStore(url: root.appending(path: "DriveProfiles.json")))
        rip.webClient = await DiscRipTests.web(toc: toc, samples: samples).client(in: root.appending(path: "cache"))
        return (try await rip.run(), root)
    }

    /// The rip reads the audio session only, whether it rips the disc (as the command-line tool
    /// does) or the tracks that the app chose, and CTDB verifies it. Track 4 is never read,
    /// even when asked for. AccurateRip still counts it: track 2 is not its last track.
    @Test(arguments: [nil, [1, 2], [1, 2, 4]] as [[Int]?])
    func ripsTheAudioSessionAndVerifiesItInCTDB(tracks: [Int]?) async throws {
        let (result, root) = try await rip(tracks: tracks)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(result.report.tracks.map(\.number) == [1, 2])
        #expect(result.report.tracks.map(\.accurateRip) == [.accurate, .accurate])
        #expect(result.report.ctdb.status == .verified)
        #expect(result.report.tracks.map(\.ctdbConfidence) == [5, 5])
        #expect(result.report.isVerified)
        #expect(FileManager.default.fileExists(atPath: result.folder.appending(path: "disc.json").path))
        #expect(!FileManager.default.fileExists(atPath: result.folder.appending(path: "Track 04.wav").path))
    }

    /// Check Again and Repair take the rip's two tracks as the whole disc.
    @Test func checksAndRepairsTheAudioSession() async throws {
        let (toc, samples) = try Self.smallDisc()
        let (result, root) = try await rip(tracks: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        let web = DiscRipTests.web(toc: toc, samples: samples)

        // A report from before the CTDB check, so that Check Again looks the disc up in CTDB.
        let file = result.folder.appending(path: "disc.json")
        var report = try RipReport.read(from: file)
        report.ctdb = RipReport.CTDBResult(status: .notChecked)
        for index in report.tracks.indices { report.tracks[index].ctdbConfidence = 0 }
        try report.write(to: file)
        var check = RipCheck(reportAt: file)
        check.webClient = await web.client(in: root.appending(path: "check cache"))
        let checked = try await check.run()
        #expect(checked.after.ctdb.status == .verified)
        #expect(checked.after.tracks.map(\.ctdbConfidence) == [5, 5])

        var repair = RipRepair(toc: toc, folders: [result.folder])
        repair.webClient = await web.client(in: root.appending(path: "repair cache"))
        let repaired = try await repair.run()
        guard case .verified = repaired.outcome else {
            Issue.record("Expected verified, got \(repaired.outcome)")
            return
        }
        #expect(repaired.trackConfidences == [5, 5, 0])
        #expect(!FileManager.default.fileExists(atPath: repair.output.path))
    }
}

/// Radiohead *Hail to the Thief* (EMI, Cactus Data Shield 200, ripped on the MATSHITA
/// 2026-10-30): C2 errors about every 450 sectors in every track, the drive's fill where the
/// protection took out audio. Every track was accurate in AccurateRip.
struct CopyProtectionGridTests {
    /// The first read's C2 sectors of tracks 1, 6, 10, and 13.
    static let flagged: [[Int]] = [
        [
            781, 782, 1242, 1692, 2142, 2581, 2582, 2592, 3032, 3042, 3932, 4392, 4832, 4842, 5282, 5732, 6192,
            6632, 7092, 7992, 8432, 8892, 9332, 9342, 9792, 10232, 10692, 11132, 13382, 13392, 13842,
        ],
        [
            797, 807, 1247, 1697, 1707, 2597, 2607, 3047, 3497, 3506, 3507, 5297, 5747, 5756, 5757, 6646, 6647,
            7557, 8007, 8447, 8896, 8897, 8907, 9347, 9357, 10257, 10697, 11147, 11157, 11597, 11607, 12957, 13407,
            13857, 14297, 15657, 16097, 16107, 16557, 16997, 17447, 17897, 17907, 18797, 18807, 19246, 19247, 19257,
        ],
        [825, 2175, 2185, 3985, 4425, 4435, 4885, 5335, 5775, 6235, 7125, 7135, 7575, 7585],
        [
            800, 810, 1249, 1250, 1700, 1710, 2150, 3060, 4400, 4410, 4850, 5760, 6200, 6210, 7110, 7550, 8000,
            8900, 8910, 9350, 9800, 9810, 10700, 10710, 11150, 11160, 11600, 11610, 12050, 12500, 12510, 12949,
            12950, 12960, 13410, 14300, 14310,
        ],
    ]

    func report(_ c2: [[Int]?]) throws -> RipReport {
        let drive = RipReport.Drive(
            vendor: "MATSHITA", product: "BD-MLT UJ260AF", revision: "1.00", readOffset: 103,
            offsetSource: "AccurateRip")
        let tracks = c2.enumerated().map { index, sectors in
            var track = RipReport.Track(
                number: index + 1, file: String(format: "Track %02d.wav", index + 1), startLBA: index * 20000,
                sectors: 20000, preEmphasis: false, accurateRip: .accurate)
            track.c2Sectors = sectors
            return track
        }
        let toc = try TOC(
            tracks: tracks.map { TOC.Track(number: $0.number, startLBA: $0.startLBA) }, leadOutLBA: c2.count * 20000)
        return RipReport(drive: drive, secure: true, toc: toc, tracks: tracks, ctdb: .init(status: .verified))
    }

    @Test func notesTheGridOfCopyProtection() throws {
        let protected = try report(Self.flagged)
        #expect(protected.copyProtectionGridTracks == [1, 2, 3, 4])
        #expect(protected.copyProtectionNote?.hasPrefix("Copy protection: the C2 errors come about every 450") == true)
        #expect(protected.copyProtectionNote?.contains("in every track") == true)
        #expect(protected.markdown.contains("Cactus Data Shield"))
        // A track with no C2 errors, one verified at once: still most of the tracks.
        #expect(try report(Self.flagged + [[]]).copyProtectionNote?.contains("in 4 of 5 tracks") == true)
    }

    @Test func leavesOtherC2ErrorsAlone() throws {
        // A scratch: once a turn of the disc, about 12 sectors at the outer edge.
        let scratch = Array(stride(from: 3000, to: 3600, by: 12))
        // A worn disc: errors here and there.
        let worn = [120, 2210, 2213, 5077, 9300, 9318, 12001, 14444, 17020]
        #expect(!RipReport.isOnProtectionGrid(scratch))
        #expect(!RipReport.isOnProtectionGrid(worn))
        #expect(try report([scratch, worn, scratch, worn]).copyProtectionNote == nil)
        // Too few tracks on the grid, or too few of those with errors.
        #expect(try report(Array(Self.flagged.prefix(2)) + [nil, nil, nil]).copyProtectionNote == nil)
        #expect(try report(Self.flagged + [worn, worn]).copyProtectionNote == nil)
        #expect(try report([nil, nil, nil]).copyProtectionNote == nil)
    }
}
