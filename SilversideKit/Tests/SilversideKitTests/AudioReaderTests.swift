import Testing

@testable import SilversideKit

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

    /// An enhanced CD: the sectors between the audio and the data session cannot be read.
    /// The last track's read ends at the audio lead-out, and the cache flush stays in the audio.
    @Test func staysInTheAudioOfAnEnhancedCD() throws {
        let (plain, samples) = try makeDisc(trackSectors: [400, 500, 600])
        let dataStart = plain.leadOutLBA + CDDA.sessionGapSectors
        let toc = try TOC(
            tracks: plain.tracks + [.init(number: 4, startLBA: dataStart, kind: .data, session: 2)],
            leadOutLBA: dataStart + 3000)
        let image = samples + [UInt32](repeating: 0, count: (toc.leadOutLBA - plain.leadOutLBA) * 588)
        let drive = SimulatedDrive(toc: toc, samples: image, readOffset: 6)
        let reader = AudioReader(drive: drive, toc: toc, readOffset: 6, canOverread: false)
        let last = toc.audioTracks[2]
        // The margin past the audio lead-out is silence, as past the edge of a plain disc. So
        // are the last 6 samples before it, which the drive's offset puts in the session gap.
        let margin = 5 * 588
        let end = toc.audioLeadOutLBA * 588
        let read = try reader.readSamples((end - margin)..<(end + margin))
        #expect(read[0..<(margin - 6)] == samples[(end - margin)..<(end - 6)])
        #expect(read[(margin - 6)...].allSatisfy { $0 == 0 })
        let before = drive.discReads
        try reader.flushCache(awayFrom: toc.sectorRange(of: last), count: 500)
        // Every flush read succeeded, so none was in the session gap or the data track.
        #expect(drive.discReads - before == (500 + reader.sectorsPerRead - 1) / reader.sectorsPerRead)
    }

    @Test func flushesInTheLargestGapFirst() {
        let gaps = AudioReader.gaps(in: [0..<1400], around: [700..<701], margin: 128)
        #expect(gaps == [0..<572, 829..<1400])
        #expect(AudioReader.gaps(in: [0..<1400], around: [0..<1400], margin: 128).isEmpty)
        #expect(
            AudioReader.gaps(in: [0..<1400], around: [100..<200, 1300..<1400], margin: 0) == [200..<1300, 0..<100])
        // A data track between two audio areas is not a gap.
        #expect(
            AudioReader.gaps(in: [0..<100, 400..<500], around: [450..<460], margin: 10) == [
                0..<100, 400..<440, 470..<500,
            ])
    }
}

/// A drive that refuses to read the Q subchannel with the audio, as a drive could.
private final class NoQWithAudioDrive: CDDrive {
    let drive: SimulatedDrive
    init(_ drive: SimulatedDrive) { self.drive = drive }

    struct Refused: Error {}

    func readTOC() throws -> TOC { try drive.readTOC() }
    func readAudioSectors(at lba: Int, count: Int) throws -> [UInt8] {
        try drive.readAudioSectors(at: lba, count: count)
    }
    func readQSubchannel(at lba: Int, count: Int) throws -> [QSubchannel] {
        try drive.readQSubchannel(at: lba, count: count)
    }
    func readAudioSectorsWithC2(at lba: Int, count: Int) throws -> (audio: [UInt8], errorFlags: [UInt8]) {
        try drive.readAudioSectorsWithC2(at: lba, count: count)
    }
    func readAudioSectors(at lba: Int, count: Int, c2: Bool, q: Bool) throws -> SectorRead {
        if q { throw Refused() }
        return try drive.readAudioSectors(at: lba, count: count, c2: c2, q: false)
    }
    func readCDText() throws -> [UInt8]? { nil }
}

struct AudioReaderQTests {
    /// The Q frames come with the audio, and a drive that refuses them still gives the audio.
    @Test(arguments: [false, true])
    func readsTheQSubchannelWithTheAudio(refused: Bool) throws {
        let (toc, samples) = try makeDisc(trackSectors: [40, 25, 60])
        let simulated = SimulatedDrive(toc: toc, samples: samples, readOffset: 6)
        simulated.qControl = [2: 0x1]
        var reader = AudioReader(
            drive: refused ? NoQWithAudioDrive(simulated) : simulated, toc: toc, readOffset: 6, canOverread: false)
        reader.sectorsPerRead = 7
        let sectors = toc.sectorRange(of: toc.tracks[1])
        let read = try reader.read(
            (sectors.lowerBound * 588)..<(sectors.upperBound * 588), withC2: false, withQ: true)
        #expect(read.samples[...] == samples[(sectors.lowerBound * 588)..<(sectors.upperBound * 588)])
        var control = SubchannelControl()
        control.add(read.q, track: 2)
        #expect(control.frames == (refused ? 0 : 25) && control.preEmphasis == control.frames)
    }
}
