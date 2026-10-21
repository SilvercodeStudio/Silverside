import Testing

@testable import CDRipKit

struct TOCTests {
    @Test func rejectsInvalidTOCs() {
        #expect(throws: TOCError.noTracks) { try TOC(tracks: [], leadOutLBA: 100) }
        #expect(throws: TOCError.invalidTrackNumbers) {
            try TOC(tracks: [.init(number: 1, startLBA: 0), .init(number: 3, startLBA: 50)], leadOutLBA: 100)
        }
        #expect(throws: TOCError.invalidStart(track: 3)) { try TOC(audioTrackStarts: [0, 50, 50], leadOutLBA: 100) }
        #expect(throws: TOCError.invalidStart(track: 1)) { try TOC(audioTrackStarts: [-1], leadOutLBA: 100) }
        #expect(throws: TOCError.invalidLeadOut) { try TOC(audioTrackStarts: [0, 50], leadOutLBA: 50) }
    }

    @Test func sectorRanges() throws {
        let toc = try TOC(audioTrackStarts: [0, 100, 250], leadOutLBA: 400)
        #expect(!toc.isEnhanced)
        #expect(toc.audioLeadOutLBA == 400)
        #expect(toc.tracks.map(toc.sectorRange(of:)) == [0..<100, 100..<250, 250..<400])
    }

    @Test func enhancedCDEndsAudioBeforeTheSessionGap() throws {
        let toc = try TOC(
            tracks: [
                .init(number: 1, startLBA: 0),
                .init(number: 2, startLBA: 1000),
                .init(number: 3, startLBA: 2000 + CDDA.sessionGapSectors, kind: .data, session: 2),
            ], leadOutLBA: 20000)
        #expect(toc.isEnhanced)
        #expect(toc.audioLeadOutLBA == 2000)
        #expect(toc.sectorRange(of: toc.tracks[1]) == 1000..<2000)
        #expect(toc.audioTracks.count == 2)
    }

    @Test func dataTrackInTheSameSessionIsNotEnhanced() throws {
        let toc = try TOC(
            tracks: [
                .init(number: 1, startLBA: 0, kind: .data),
                .init(number: 2, startLBA: 1000),
            ], leadOutLBA: 2000)
        #expect(!toc.isEnhanced)
        #expect(toc.audioLeadOutLBA == 2000)
        // The data track cannot be read as audio.
        #expect(toc.audioAreas == [1000..<2000])
    }

    @Test func audioAreasLeaveOutDataTracksAndTheSessionGap() throws {
        let plain = try TOC(audioTrackStarts: [0, 100, 250], leadOutLBA: 400)
        #expect(plain.audioAreas == [0..<400])
        let enhanced = try TOC(
            tracks: [
                .init(number: 1, startLBA: 0),
                .init(number: 2, startLBA: 1000),
                .init(number: 3, startLBA: 2000 + CDDA.sessionGapSectors, kind: .data, session: 2),
            ], leadOutLBA: 20000)
        #expect(enhanced.audioAreas == [0..<2000])
    }

    /// An enhanced CD's data track must start more than the session gap after the last audio track.
    @Test func rejectsADataSessionTooCloseToTheAudio() {
        #expect(throws: TOCError.invalidStart(track: 3)) {
            try TOC(
                tracks: [
                    .init(number: 1, startLBA: 0),
                    .init(number: 2, startLBA: 1000),
                    .init(number: 3, startLBA: 1000 + CDDA.sessionGapSectors, kind: .data, session: 2),
                ], leadOutLBA: 20000)
        }
    }
}

struct FullTOCTests {
    /// DKIOCCDREADTOC output for Grateful Dead, "Dozin' at the Knick", disc 1 (MATSHITA BD-MLT UJ260AF).
    static let dozinDisc1 = hexBytes(
        """
        00860101
        011000A000000000010000 011000A100000000090000 011000A200000000412B00
        0110000100000000000200 0110000200000000070032 01100003000000000C3923
        011000040000000011303C 011000050000000018292B 01100006000000001D0A28
        011000070000000024312B 01100008000000002A2B3A 0110000900000000360349
        """)

    @Test func parsesAudioCD() throws {
        let toc = try TOC(fullTOC: Self.dozinDisc1)
        #expect(toc.tracks.map(\.startLBA) == [0, 31400, 58160, 80010, 110968, 131140, 165568, 192133, 243148])
        #expect(toc.leadOutLBA == 295575)
        #expect(toc.tracks.allSatisfy { $0.kind == .audio && $0.session == 1 && !$0.hasPreEmphasis })
        // Both agree with the MusicBrainz release and the AccurateRip database.
        #expect(toc.musicBrainzDiscID == "qlxTvL1MjvcBDy5MraVOjxWJ8ec-")
        #expect(
            toc.accurateRipDiscID.databaseURL.absoluteString
                == "http://www.accuraterip.com/accuraterip/6/c/5/dBAR-009-0013f5c6-00949b73-700f6509.bin")
    }

    @Test func readsControlBits() throws {
        // Track 1 audio with pre-emphasis and copy permitted (control 3), track 2 data (control 4).
        let bytes = hexBytes(
            """
            00250101
            011000A2000000000A0000 0113000100000000000200 0114000200000000050000
            """)
        let toc = try TOC(fullTOC: bytes)
        #expect(toc.tracks[0].hasPreEmphasis && toc.tracks[0].isCopyPermitted)
        #expect(toc.tracks[1].kind == .data && !toc.tracks[1].hasPreEmphasis)
        #expect(toc.leadOutLBA == 10 * 60 * 75 - 150)
    }

    /// An enhanced CD: two audio tracks in session 1, a data track in session 2. The lead-out
    /// of the last session is the disc's.
    @Test func parsesTwoSessions() throws {
        func descriptor(session: UInt8, control: UInt8, point: UInt8, lba: Int) -> [UInt8] {
            let msf = lba + CDDA.leadInSectors
            let (minute, second, frame) = (msf / 4500, msf / 75 % 60, msf % 75)
            return [session, 0x10 | control, 0, point, 0, 0, 0, 0, UInt8(minute), UInt8(second), UInt8(frame)]
        }
        let dataStart = 20000 + CDDA.sessionGapSectors
        let descriptors =
            descriptor(session: 1, control: 0, point: 0xA0, lba: 1 * 4500 - 150)
            + descriptor(session: 1, control: 0, point: 0xA1, lba: 2 * 4500 - 150)
            + descriptor(session: 1, control: 0, point: 0xA2, lba: 20000)
            + descriptor(session: 1, control: 0, point: 1, lba: 0)
            + descriptor(session: 1, control: 0, point: 2, lba: 10000)
            + descriptor(session: 2, control: 4, point: 0xA0, lba: 3 * 4500 - 150)
            + descriptor(session: 2, control: 4, point: 0xA1, lba: 3 * 4500 - 150)
            + descriptor(session: 2, control: 4, point: 0xA2, lba: 50000)
            + descriptor(session: 2, control: 4, point: 3, lba: dataStart)
        let length = 2 + descriptors.count
        let toc = try TOC(fullTOC: [UInt8(length >> 8), UInt8(length & 0xFF), 1, 2] + descriptors)
        #expect(toc.tracks.map(\.startLBA) == [0, 10000, dataStart])
        #expect(toc.tracks.map(\.session) == [1, 1, 2] && toc.tracks[2].kind == .data)
        #expect(toc.leadOutLBA == 50000 && toc.isEnhanced && toc.audioLeadOutLBA == 20000)
        #expect(toc.audioAreas == [0..<20000])
    }

    @Test func rejectsTOCWithoutLeadOut() {
        #expect(throws: TOCError.malformed) { try TOC(fullTOC: hexBytes("000D0101 0110000100000000000200")) }
        #expect(throws: TOCError.malformed) { try TOC(fullTOC: [0, 2]) }
    }
}
