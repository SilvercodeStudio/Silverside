import Testing

@testable import CDRipKit

struct SecureRipperTests {
    static let driveOffset = 667

    /// A three-track disc, its AccurateRip record, and a drive with the given damage
    /// in the middle track (sectors 460 to 929). The cache flush can read 460 sectors
    /// on each side of that track, so a cache must be smaller for a flush to empty it.
    func setUp(
        unstable: Set<Int> = [], corrupt: Set<Int> = [], cacheSectors: Int = 0, withRecords: Bool = true
    ) throws -> (secure: SecureRipper, toc: TOC, samples: [UInt32], drive: SimulatedDrive) {
        let (toc, samples, record) = try TrackRipperTests().disc()
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: Self.driveOffset)
        drive.unstableSectors = unstable
        drive.corruptSectors = corrupt
        drive.cacheSectors = cacheSectors
        let reader = AudioReader(drive: drive, toc: toc, readOffset: Self.driveOffset, canOverread: false)
        var secure = SecureRipper(ripper: TrackRipper(reader: reader, records: withRecords ? [record] : []))
        secure.cacheFlushSectors = toc.leadOutLBA
        return (secure, toc, samples, drive)
    }

    func trueSamples(of track: TOC.Track, in toc: TOC, _ samples: [UInt32]) -> ArraySlice<UInt32> {
        let sectors = toc.sectorRange(of: track)
        return samples[(sectors.lowerBound * 588)..<(sectors.upperBound * 588)]
    }

    @Test func acceptsAnAccurateFirstRead() throws {
        let (secure, toc, _, drive) = try setUp()
        let rip = try secure.rip(toc.tracks[1])
        #expect(rip.status == .accurate(v1Confidence: 0, v2Confidence: 4))
        #expect(rip.rounds == 0 && rip.suspectSectors.isEmpty)
        #expect(drive.discReads > 0)
    }

    /// Sectors that read wrong at random: re-reads give both versions, and testing
    /// the combinations against AccurateRip finds the true data.
    @Test func findsTheTrueDataOfUnstableSectors() throws {
        let (secure, toc, samples, _) = try setUp(unstable: [500, 501, 620, 700, 701, 702, 850, 900])
        let track = toc.tracks[1]
        let rip = try secure.rip(track)
        #expect(rip.status == .accurate(v1Confidence: 0, v2Confidence: 4))
        #expect(rip.unresolvedSectors.isEmpty)
        #expect(!rip.suspectSectors.isEmpty)
        #expect(rip.samples[...] == trueSamples(of: track, in: toc, samples))
    }

    /// Without reading elsewhere first, the second read comes from the cache, and
    /// the damage cannot be seen.
    @Test func cacheHidesDamageWithoutAFlush() throws {
        // The cache holds the whole track, so the second read is all from the cache.
        var (secure, toc, _, _) = try setUp(unstable: Set(500..<510), cacheSectors: 600)
        secure.cacheFlushSectors = 0
        let rip = try secure.rip(toc.tracks[1])
        #expect(rip.status == .consistentButNotAccurate)
        #expect(rip.suspectSectors.isEmpty)
    }

    @Test func flushesTheCacheBeforeReReading() throws {
        let (secure, toc, samples, _) = try setUp(unstable: Set(500..<510), cacheSectors: 300)
        let track = toc.tracks[1]
        let rip = try secure.rip(track)
        #expect(rip.status == .accurate(v1Confidence: 0, v2Confidence: 4))
        #expect(rip.samples[...] == trueSamples(of: track, in: toc, samples))
    }

    /// An error that reads the same every time looks like a pressing that is not in AccurateRip.
    @Test func reportsAConsistentError() throws {
        let (secure, toc, _, _) = try setUp(corrupt: [600])
        let rip = try secure.rip(toc.tracks[1])
        #expect(rip.status == .consistentButNotAccurate)
        #expect(rip.rounds == 0)
    }

    @Test func comparesTwoReadsWithoutAccurateRip() throws {
        let (secure, toc, _, _) = try setUp(withRecords: false)
        let rip = try secure.rip(toc.tracks[1])
        #expect(rip.status == .consistent && rip.rounds == 0)
    }

    /// Without AccurateRip, sectors that keep reading two ways stay unresolved, and
    /// the re-reads stop once no new versions appear.
    @Test func leavesUnstableSectorsUnresolvedWithoutAccurateRip() throws {
        let (secure, toc, _, _) = try setUp(unstable: [500, 501], withRecords: false)
        let rip = try secure.rip(toc.tracks[1])
        #expect(rip.status == .suspect)
        #expect(!rip.unresolvedSectors.isEmpty)
        #expect(rip.rounds < secure.maximumRounds)
    }

    /// Too many unstable sectors to test every combination: the track stays suspect.
    @Test func givesUpOnTooManyCombinations() throws {
        var (secure, toc, _, _) = try setUp(unstable: Set(stride(from: 470, to: 920, by: 15)))
        secure.maximumRounds = 3
        let rip = try secure.rip(toc.tracks[1])
        #expect(rip.status == .suspect)
        #expect(rip.unresolvedSectors == rip.suspectSectors)
    }

    @Test func joinsNearbySectorsIntoRuns() {
        #expect(SecureRipper.runs(of: [1, 2, 4, 8, 9, 20]) == [1..<5, 8..<10, 20..<21])
        #expect(SecureRipper.runs(of: []) == [])
    }
}

struct AccurateRipContributionTests {
    @Test func partsAddUpToTheTrackChecksum() throws {
        let (_, samples) = try makeDisc(trackSectors: [20])
        for (first, last) in [(false, false), (true, false), (false, true), (true, true)] {
            let whole = AccurateRipAccumulator.checksum(of: samples.span, isFirstTrack: first, isLastTrack: last)
            var sum = AccurateRipChecksum.zero
            for start in stride(from: 0, to: samples.count, by: 588) {
                let part = Array(samples[start..<(start + 588)])
                sum =
                    sum
                    + AccurateRipAccumulator.contribution(
                        of: part.span, at: start + 1, sampleCount: samples.count, isFirstTrack: first, isLastTrack: last
                    )
            }
            #expect(sum == whole)
        }
    }
}
