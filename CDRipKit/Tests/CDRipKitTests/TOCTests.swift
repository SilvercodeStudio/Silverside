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
    }
}
