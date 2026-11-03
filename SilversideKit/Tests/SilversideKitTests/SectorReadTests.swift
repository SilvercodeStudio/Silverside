import Testing

@testable import SilversideKit

struct SectorReadTests {
    /// Three sectors of a read with C2 flags and Q, as a drive returns them: each sector's user
    /// area, then its flags and its Q in `layout`'s order. Sector 1 has a damaged Q frame.
    func raw(_ layout: SectorRead.Layout) -> (bytes: [UInt8], frames: [QSubchannel], flags: [UInt8]) {
        let frames = (0..<3).map { QSubchannel.position(track: 2, index: 1, lba: 1000 + $0) }
        var bytes = [UInt8]()
        var allFlags = [UInt8]()
        for sector in 0..<3 {
            bytes += [UInt8](repeating: UInt8(sector + 1), count: CDDA.bytesPerSector)
            var flags = [UInt8](repeating: 0, count: CDDA.errorFlagBytesPerSector)
            flags[sector] = 0x80
            var q = frames[sector].bytes + [0, 0, 0, 0x80]
            if sector == 1 { q[3] ^= 0xFF }
            bytes += layout == .flagsThenQ ? flags + q : q + flags
            allFlags += flags
        }
        return (bytes, frames, allFlags)
    }

    @Test(arguments: [SectorRead.Layout.flagsThenQ, .qThenFlags])
    func findsWhereTheQFramesAre(layout: SectorRead.Layout) {
        let (bytes, frames, flags) = raw(layout)
        #expect(SectorRead.layout(of: bytes, count: 3) == layout)
        let read = SectorRead(raw: bytes, count: 3, c2: true, q: true, layout: layout)
        #expect(read.audio == (1...3).flatMap { [UInt8](repeating: UInt8($0), count: CDDA.bytesPerSector) })
        #expect(read.errorFlags == flags)
        #expect(read.q.map(\.isValid) == [true, false, true])
        #expect(read.q[0].bytes == frames[0].bytes && read.q[2].bytes == frames[2].bytes)
    }

    /// Read in MMC's order, a drive that puts Q first gives a C2 error in every sector and no Q.
    @Test func readsQFirstWrongInMMCOrder() {
        let (bytes, _, _) = raw(.qThenFlags)
        let read = SectorRead(raw: bytes, count: 3, c2: true, q: true)
        #expect(read.q.allSatisfy { !$0.isValid })
        #expect(
            (0..<3).allSatisfy { sector in read.errorFlags[(sector * 294)..<(sector * 294 + 16)].contains { $0 != 0 } })
    }

    @Test func knowsNoLayoutWithoutAValidFrame() {
        let bytes = [UInt8](repeating: 0, count: 2 * (CDDA.bytesPerSector + CDDA.errorFlagBytesPerSector + 16))
        #expect(SectorRead.layout(of: bytes, count: 2) == nil)
    }

    @Test func splitsReadsWithOnePayload() {
        let flagsOnly = [UInt8](repeating: 7, count: CDDA.bytesPerSector) + [UInt8](repeating: 1, count: 294)
        let withFlags = SectorRead(raw: flagsOnly, count: 1, c2: true, q: false)
        #expect(
            withFlags.audio.count == CDDA.bytesPerSector && withFlags.errorFlags == [UInt8](repeating: 1, count: 294))
        let frame = QSubchannel.position(track: 1, index: 1, lba: 5)
        let qOnly = [UInt8](repeating: 7, count: CDDA.bytesPerSector) + frame.bytes + [0, 0, 0, 0]
        let withQ = SectorRead(raw: qOnly, count: 1, c2: false, q: true, layout: .qThenFlags)
        #expect(withQ.errorFlags.isEmpty && withQ.q[0].bytes == frame.bytes)
    }
}
