import Testing

@testable import CDRipKit

struct AudioReaderTests {
    static let trackSectors = [40, 25, 60]

    func trueTrack(_ number: Int, toc: TOC, samples: [UInt32]) -> ArraySlice<UInt32> {
        let sectors = toc.sectorRange(of: toc.track(number)!)
        return samples[(sectors.lowerBound * CDDA.samplesPerSector)..<(sectors.upperBound * CDDA.samplesPerSector)]
    }

    func accurateRip(_ samples: some Collection<UInt32>, track: Int, of toc: TOC) -> AccurateRipChecksum {
        let samples = Array(samples)
        return AccurateRipAccumulator.checksum(
            of: samples[...],
            isFirstTrack: track == toc.tracks.first!.number,
            isLastTrack: track == toc.tracks.last!.number
        )
    }

    @Test(arguments: [-1234, -6, 0, 6, 30, 667, 1776], [false, true])
    func correctedReadsMatchTheDisc(offset: Int, canOverread: Bool) throws {
        let (toc, samples) = try makeDisc(trackSectors: Self.trackSectors)
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: offset, canOverread: canOverread)
        var reader = AudioReader(drive: drive, toc: toc, readOffset: offset, canOverread: canOverread)
        reader.sectorsPerRead = 7

        for track in toc.tracks {
            let read = try reader.readTrack(track)
            let expected = trueTrack(track.number, toc: toc, samples: samples)
            // Without overread, samples beyond the disc edges are silence. AccurateRip skips them.
            if canOverread || (track.number == 2) {
                #expect(read[...] == expected, "Track \(track.number)")
            }
            #expect(
                accurateRip(read, track: track.number, of: toc) == accurateRip(expected, track: track.number, of: toc))
        }
    }

    @Test func uncorrectedReadsDoNotMatch() throws {
        let (toc, samples) = try makeDisc(trackSectors: Self.trackSectors)
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: 6)
        let reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
        let track = toc.tracks[1]
        #expect(
            accurateRip(try reader.readTrack(track), track: 2, of: toc)
                != accurateRip(trueTrack(2, toc: toc, samples: samples), track: 2, of: toc))
    }

    @Test func corruptSectorChangesOnlyItsTrack() throws {
        let (toc, samples) = try makeDisc(trackSectors: Self.trackSectors)
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: 6)
        drive.corruptSectors = [50]
        let reader = AudioReader(drive: drive, toc: toc, readOffset: 6, canOverread: false)
        let matches = try toc.tracks.map { track in
            accurateRip(try reader.readTrack(track), track: track.number, of: toc)
                == accurateRip(trueTrack(track.number, toc: toc, samples: samples), track: track.number, of: toc)
        }
        #expect(matches == [true, false, true])
    }

    @Test func readErrorsArePassedOn() throws {
        let (toc, samples) = try makeDisc(trackSectors: Self.trackSectors)
        let drive = SimulatedDrive(toc: toc, samples: samples)
        drive.unreadableSectors = [45]
        let reader = AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
        #expect(throws: DriveError.readFailed(lba: 45)) { try reader.readTrack(toc.tracks[1]) }
    }

    @Test func driveWithoutOverreadRejectsSectorsPastTheLeadOut() throws {
        let (toc, samples) = try makeDisc(trackSectors: Self.trackSectors)
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: 6)
        // The reader expects overread, but the drive does not support it.
        let reader = AudioReader(drive: drive, toc: toc, readOffset: 6, canOverread: true)
        #expect(throws: DriveError.sectorOutOfRange(lba: toc.leadOutLBA)) { try reader.readTrack(toc.tracks[2]) }
    }
}
