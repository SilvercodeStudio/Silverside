import Testing

@testable import CDRipKit

struct DiscIDTests {
    struct MusicBrainzDisc: Sendable, CustomTestStringConvertible {
        let id: String
        let sectors: Int
        let offsets: [Int]
        var testDescription: String { id }
    }

    /// Grateful Dead, "Summer Magic 1985", discs 1-20, from the MusicBrainz web service.
    static let summerMagic: [MusicBrainzDisc] = [
        .init(
            id: "cSSZg7afX7pWiwu07gorqRLM2uY-", sectors: 308455,
            offsets: [150, 35062, 70883, 100200, 130150, 161793, 184666, 208613, 258905, 287935]),
        .init(
            id: "zABLkk.irp.yU71nzhcdpMtr_sI-", sectors: 342089,
            offsets: [150, 5747, 57531, 105627, 136967, 148170, 191345, 226620, 255831, 275195, 300517]),
        .init(
            id: "l3V.w77Bu772nHOoC8Uqk63aA6g-", sectors: 224677,
            offsets: [150, 34070, 67338, 109811, 136792, 167288, 181136, 205257]),
        .init(
            id: "ugMtpdHFtO.Zr3VpnwlWeKvBG6s-", sectors: 219202, offsets: [150, 30049, 54720, 83875, 112295, 168229]),
        .init(
            id: "Lc.wxYH74gPgZIyj7Wy1YXtHhK4-", sectors: 193240,
            offsets: [150, 33773, 53786, 71898, 106896, 135800, 171467]),
        .init(
            id: "TX24GGLsUPjc_j9ObM4FGXWh.Go-", sectors: 242543,
            offsets: [150, 22023, 48662, 79848, 118513, 140389, 160113, 195190, 224819]),
        .init(id: "LwVjyb5bDuaNQHY6UZ2fsEH0Kx0-", sectors: 229574, offsets: [150, 54862, 101175, 137065, 187449]),
        .init(
            id: "osT.ZJo7Il2Efz6sxb.gCGuIRnI-", sectors: 182822, offsets: [150, 34767, 61380, 78246, 121493, 156749]),
        .init(
            id: "ibCFLafHl7GWl2frBRAzeJBlsnk-", sectors: 284354,
            offsets: [150, 20524, 43287, 84850, 114500, 138425, 177989, 198637, 235279, 267878]),
        .init(id: "VBbFodcWYwfKSsDX8vbsgscyQ.w-", sectors: 191249, offsets: [150, 47472, 88407, 108254, 139417]),
        .init(
            id: "SuiksLGrYe_nuQGhU8wMOrEsBXk-", sectors: 223591,
            offsets: [150, 38653, 68718, 89042, 125229, 166385, 187866]),
        .init(
            id: "w56WucZGJPnUz.HtOX333820zfY-", sectors: 207149,
            offsets: [150, 29048, 50082, 81168, 114443, 146043, 175726]),
        .init(id: "c_CPp.CT8P2Zpp5Gim0rehG4jOU-", sectors: 232157, offsets: [150, 45231, 67739, 120522, 171279]),
        .init(
            id: "Avfo6wc0aZYNUmTjiDUQmO0MjuU-", sectors: 196135, offsets: [150, 29545, 48110, 96969, 137533, 175799]),
        .init(
            id: "MLzzYYav7u43nhQNUdCgk5gMvE8-", sectors: 226471,
            offsets: [150, 37477, 73866, 101063, 113421, 137155, 158001, 176863, 212572]),
        .init(
            id: "SB62ajIMvdBHZkWu5N.r3PN6T14-", sectors: 256665, offsets: [150, 68658, 106262, 131072, 186462, 195004]),
        .init(
            id: "Ki7c5dMrG6CxBNUWRX4Iw7WiJIU-", sectors: 189068, offsets: [150, 35473, 66759, 107555, 124601, 165935]),
        .init(
            id: "NP5_TDVkRzF2neyU9M3iKidg_iw-", sectors: 265408,
            offsets: [150, 33415, 65352, 105579, 131055, 152938, 188470, 246071]),
        .init(id: "HcHJP.xP0v3c4Lkubbvr8ya8LKY-", sectors: 249204, offsets: [150, 53688, 106871, 148794, 207974]),
        .init(
            id: "FMAfH6DXbTVuPZeufpGdQkxEdGo-", sectors: 197217, offsets: [150, 44706, 70853, 97696, 140549, 164715]),
    ]

    @Test(arguments: summerMagic)
    func musicBrainzDiscID(disc: MusicBrainzDisc) throws {
        let toc = try TOC(musicBrainzOffsets: disc.offsets, sectors: disc.sectors)
        #expect(toc.musicBrainzDiscID == disc.id)
    }

    /// MusicBrainz leaves out the data track and puts the lead-out 11400 sectors before it.
    @Test func musicBrainzDiscIDOfEnhancedCDIgnoresTheDataTrack() throws {
        let disc = Self.summerMagic[0]
        let audioOnly = try TOC(musicBrainzOffsets: disc.offsets, sectors: disc.sectors)
        let dataStart = audioOnly.leadOutLBA + CDDA.sessionGapSectors
        let enhanced = try TOC(
            tracks: audioOnly.tracks + [.init(number: 11, startLBA: dataStart, kind: .data, session: 2)],
            leadOutLBA: dataStart + 30000
        )
        #expect(enhanced.musicBrainzDiscID == disc.id)
    }

    /// Nirvana, "Nevermind", two pressings. The AccurateRip database has a record at each URL.
    @Test(arguments: [
        (
            [150, 22767, 41887, 58317, 72102, 91375, 104652, 115380, 132165, 143932, 159870, 174597], 267225,
            "2y0jFMwYQP7gb9iSUKagmoT6DIw-",
            "http://www.accuraterip.com/accuraterip/5/4/8/dBAR-012-00151845-00c504b0-a70de90c.bin"
        ),
        (
            [150, 22812, 41947, 58380, 72187, 91485, 104675, 115405, 132210, 143990, 159942, 174687], 267507,
            "4HygHMwFE8DplriX8TdvDdoyHWs-",
            "http://www.accuraterip.com/accuraterip/3/0/c/dBAR-012-00151c03-00c525db-af0dec0c.bin"
        ),
    ])
    func accurateRipDiscID(offsets: [Int], sectors: Int, musicBrainzID: String, url: String) throws {
        let toc = try TOC(musicBrainzOffsets: offsets, sectors: sectors)
        #expect(toc.musicBrainzDiscID == musicBrainzID)
        #expect(toc.accurateRipDiscID.databaseURL.absoluteString == url)
    }

    @Test func freedbDiscID() throws {
        let disc = Self.summerMagic[0]
        let toc = try TOC(musicBrainzOffsets: disc.offsets, sectors: disc.sectors)
        #expect(toc.freedbDiscID == 0x9610_0E0A)
    }

    /// CTDB returned records for this TOC string (Summer Magic disc 1).
    @Test func ctdbTOCString() throws {
        let disc = Self.summerMagic[0]
        let toc = try TOC(musicBrainzOffsets: disc.offsets, sectors: disc.sectors)
        #expect(toc.ctdbTOCString == "0:34912:70733:100050:130000:161643:184516:208463:258755:287785:308305")
    }
}
