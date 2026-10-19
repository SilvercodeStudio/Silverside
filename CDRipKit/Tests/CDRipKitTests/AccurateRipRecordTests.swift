import Foundation
import Testing

@testable import CDRipKit

struct AccurateRipRecordTests {
    /// The AccurateRip database file for "Dozin' at the Knick", disc 1, fetched 2026-10-19.
    static func dozinDisc1() throws -> [UInt8] {
        let url = try #require(
            Bundle.module.url(
                forResource: "dBAR-009-0013f5c6-00949b73-700f6509", withExtension: "bin", subdirectory: "Resources"))
        return try [UInt8](Data(contentsOf: url))
    }

    @Test func parsesDatabaseFile() throws {
        let records = try AccurateRipRecord.records(from: Self.dozinDisc1())
        #expect(records.count == 11)
        let toc = try TOC(fullTOC: FullTOCTests.dozinDisc1)
        #expect(records.allSatisfy { $0.discID == toc.accurateRipDiscID && $0.tracks.count == 9 })
        #expect(records[0].tracks[0].confidence == 58)
        #expect(records[0].tracks[0].checksum == 0xD953_5D76)
    }

    @Test func rejectsTruncatedFile() throws {
        let bytes = try Self.dozinDisc1()
        #expect(throws: AccurateRipError.malformedResponse) {
            try AccurateRipRecord.records(from: Array(bytes.dropLast()))
        }
    }
}

struct AccurateRipOffsetFinderTests {
    @Test(arguments: [-1500, -6, 0, 6, 103, 667, 1500])
    func findsTheDriveOffset(offset: Int) throws {
        let (toc, samples) = try makeDisc(trackSectors: [20, 30, 20])
        let track = toc.sectorRange(of: toc.tracks[1])
        let positions = (track.lowerBound * CDDA.samplesPerSector)..<(track.upperBound * CDDA.samplesPerSector)
        let trueTrack = Array(samples[positions])
        let checksum = AccurateRipAccumulator.checksum(of: trueTrack.span, isFirstTrack: false, isLastTrack: false)

        // Read with no correction, from a drive with an unknown offset.
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: offset)
        let reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
        let margin = 2000
        let read = try reader.readSamples((positions.lowerBound - margin)..<(positions.upperBound + margin))

        let found = AccurateRipOffsetFinder.offsets(
            matching: [checksum.v1], in: read, trackLength: positions.count, margin: margin)
        #expect(found == [offset])
    }

    @Test func findsNothingForAnUnknownChecksum() throws {
        let (_, samples) = try makeDisc(trackSectors: [10])
        #expect(AccurateRipOffsetFinder.offsets(matching: [1], in: samples, trackLength: 588 * 8, margin: 588).isEmpty)
    }
}
