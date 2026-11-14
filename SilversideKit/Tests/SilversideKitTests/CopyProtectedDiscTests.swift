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
}
