import Foundation
import Testing

@testable import SilversideKit

struct QSubchannelTests {
    /// Read from LBA 1000 of "Dozin' at the Knick", disc 1.
    static let realFrame = hexBytes("010101001325000015254b8c")

    @Test func parsesARealFrame() {
        let frame = QSubchannel(bytes: Self.realFrame)
        #expect(frame.isValid)
        #expect(frame.position == QSubchannel.Position(track: 1, index: 1, lba: 1000))
    }

    /// Read from Phish, "The Story of the Ghost": LBA 17441 and 89520.
    @Test func parsesRealMCNAndISRCFrames() {
        let mcn = QSubchannel(bytes: hexBytes("020075596229722000411d32"))
        #expect(mcn.mcn == "0075596229722" && mcn.position == nil && mcn.isrc == nil)
        let isrc = QSubchannel(bytes: hexBytes("0396355504980019304587a6"))
        #expect(isrc.isrc == "USEE19800193" && isrc.position == nil && isrc.mcn == nil)
    }

    @Test func makesCodeFramesThatParse() {
        #expect(QSubchannel.mcn("0075596229722").mcn == "0075596229722")
        #expect(QSubchannel.isrc("GBN9X1400051").isrc == "GBN9X1400051")
        // The real ISRC frame stores a frame number in its last data byte; ours stores zero.
        #expect(QSubchannel.isrc("USEE19800193").bytes[0..<9] == hexBytes("0396355504980019304587a6")[0..<9])
    }

    @Test func rejectsADamagedFrame() {
        var bytes = Self.realFrame
        bytes[1] = 0x83
        #expect(!QSubchannel(bytes: bytes).isValid)
        #expect(QSubchannel(bytes: bytes).position == nil)
    }

    @Test func makesFramesThatParse() {
        let frame = QSubchannel.position(track: 12, index: 0, lba: 249441)
        #expect(frame.isValid)
        #expect(frame.position == QSubchannel.Position(track: 12, index: 0, lba: 249441))
    }
}

struct PregapFinderTests {
    func drive(pregaps: [Int: Int], trackSectors: [Int] = [400, 500, 300, 200]) throws -> SimulatedDrive {
        let (toc, samples) = try makeDisc(trackSectors: trackSectors)
        let drive = SimulatedDrive(toc: toc, samples: samples)
        drive.pregaps = pregaps
        return drive
    }

    @Test func findsPregaps() throws {
        let drive = try drive(pregaps: [2: 150, 3: 1, 4: 0])
        #expect(try PregapFinder.pregaps(of: drive.toc, drive: drive) == [1: 0, 2: 150, 3: 1, 4: 0])
    }

    @Test func readsAroundDamagedFrames() throws {
        let drive = try drive(pregaps: [2: 150, 3: 37])
        // Track 2's pregap starts at 250 and track 3's at 863. Damage the frames
        // that the binary searches read first, and the frame just after each change.
        // (A damaged frame just before a change leaves its position unknown by one sector.)
        drive.corruptQSectors = Set(199...201).union(649...651).union([251, 864])
        #expect(try PregapFinder.pregaps(of: drive.toc, drive: drive) == [1: 0, 2: 150, 3: 37, 4: 0])
    }

    /// If every frame between a known track 1 sector and a known track 2 sector is
    /// damaged, the change cannot be found. Other tracks are not affected.
    @Test func failsOnlyForTheTrackWithAnUnreadableChange() throws {
        let drive = try drive(pregaps: [2: 150, 3: 37])
        drive.corruptQSectors = Set(240...260)
        let toc = drive.toc
        #expect(throws: PregapError.self) { try PregapFinder.pregap(of: toc.tracks[1], in: toc, drive: drive) }
        #expect(try PregapFinder.pregap(of: toc.tracks[2], in: toc, drive: drive) == 37)
    }

    /// Grateful Dead, "Reckoning", has a bad CRC in the last frame before tracks 9 and 14.
    @Test func usesAFrameWithABadCRCWhenItsTimeAgrees() throws {
        let drive = try drive(pregaps: [2: 150, 3: 0])
        drive.badCRCQSectors = [249, 899]
        #expect(try PregapFinder.pregaps(of: drive.toc, drive: drive) == [1: 0, 2: 150, 3: 0, 4: 0])
    }

    /// Sector 441 holds an MCN frame, right before track 2 starts at 442 with no pregap.
    @Test func treatsACodeFrameAtTheChangeAsThePreviousTrack() throws {
        let drive = try drive(pregaps: [:], trackSectors: [442, 300])
        drive.mcn = "0075596229722"
        #expect(try PregapFinder.pregaps(of: drive.toc, drive: drive) == [1: 0, 2: 0])
    }

    @Test func leavesOutDataTracks() throws {
        let toc = try TOC(
            tracks: [.init(number: 1, startLBA: 0), .init(number: 2, startLBA: 400, kind: .data)], leadOutLBA: 900)
        let drive = SimulatedDrive(toc: toc, samples: [UInt32](repeating: 0, count: 900 * 588))
        #expect(try PregapFinder.pregaps(of: toc, drive: drive) == [1: 0])
    }
}

struct CTDBEntryTests {
    @Test func parsesLookupResponse() throws {
        let xml = """
            <ctdb xmlns="http://db.cuetools.net/ns/mmd-1.0#" xmlns:ext="http://db.cuetools.net/ns/ext-1.0#">
             <entry confidence="5905" crc32="eee95d58" hasparity="http://p.cuetools.net/5502" id="5502" npar="16" \
            stride="5880" syndrome="fYhi" toc="0:42407:86587:111905:164087:206535:249442" \
            trackcrcs="df289f01 6b238d26 849c5604 6969eaa3 155b25c0 12949d9a" />
             <entry confidence="1" crc32="2d851454" id="13069614" npar="16" stride="5880" syndrome="1M9B" \
            toc="0:42407:86587:111905:164087:206535:249442" trackcrcs="11aff243 259cbbeb" />
             <metadata />
            </ctdb>
            """
        let entries = try CTDBEntry.entries(fromXML: Data(xml.utf8))
        #expect(entries.count == 2)
        #expect(entries[0].id == 5502 && entries[0].confidence == 5905 && entries[0].crc32 == 0xEEE9_5D58)
        #expect(entries[0].trackCRCs.count == 6 && entries[0].trackCRCs[0] == 0xDF28_9F01)
        #expect(entries[0].hasParity && !entries[1].hasParity)
    }

    @Test func rejectsMalformedResponse() {
        #expect(throws: CTDBError.malformedResponse) { try CTDBEntry.entries(fromXML: Data("<ctdb><entry".utf8)) }
        #expect(throws: CTDBError.malformedResponse) {
            try CTDBEntry.entries(fromXML: Data(#"<ctdb><entry confidence="x"/></ctdb>"#.utf8))
        }
    }
}

struct SubchannelCodesTests {
    @Test func readsCodesFromFrames() throws {
        let (toc, samples) = try makeDisc(trackSectors: [600, 700, 400])
        let drive = SimulatedDrive(toc: toc, samples: samples)
        drive.mcn = "0075596229722"
        drive.isrcs = [1: "USEE19800189", 2: "USEE19800190"]
        #expect(try SubchannelCodes.mcn(in: toc, drive: drive) == "0075596229722")
        let isrcs = try toc.tracks.map { try SubchannelCodes.isrc(of: $0, in: toc, drive: drive) }
        #expect(isrcs == ["USEE19800189", "USEE19800190", nil])
    }

    @Test func treatsAnMCNOfZerosAsNone() throws {
        let (toc, samples) = try makeDisc(trackSectors: [600])
        let drive = SimulatedDrive(toc: toc, samples: samples)
        drive.mcn = "0000000000000"
        #expect(try SubchannelCodes.mcn(in: toc, drive: drive) == nil)
    }
}
