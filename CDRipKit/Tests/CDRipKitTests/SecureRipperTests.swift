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
        // A track that does not match AccurateRip gets every full read while none shows new suspects.
        #expect(rip.fullReads == secure.maximumFullReads)
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

    /// A disc with one track has no room outside it, so the flush reads inside the track,
    /// away from the suspect sectors. Without it, re-reads come from the cache and repeat one
    /// version, which wins by the agreement margin although it is wrong.
    @Test(arguments: [false, true])
    func flushesInsideADiscWithOneTrack(withRecords: Bool) throws {
        let (toc, samples) = try makeDisc(trackSectors: [1400])
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: 6)
        drive.unstableSectors = [700]
        drive.cacheSectors = 100
        let trackSamples = Array(samples[0..<(1400 * 588)])
        let checksum = AccurateRipAccumulator.checksum(of: trackSamples[...], isFirstTrack: true, isLastTrack: true)
        let sector450 = Array(trackSamples[(450 * 588)..<(451 * 588)])
        let frame450 = AccurateRipAccumulator.checksum(of: sector450[...], isFirstTrack: false, isLastTrack: false)
        let record = AccurateRipRecord(
            discID: toc.accurateRipDiscID,
            tracks: [.init(confidence: 3, checksum: checksum.v2, frame450Checksum: frame450.v1)])
        let reader = AudioReader(drive: drive, toc: toc, readOffset: 6, canOverread: false)
        let secure = SecureRipper(ripper: TrackRipper(reader: reader, records: withRecords ? [record] : []))
        let rip = try secure.rip(toc.tracks[0])
        let sector = (700 * 588 - 6)..<(701 * 588 - 6)
        if withRecords {
            #expect(rip.status == .accurate(v1Confidence: 0, v2Confidence: 3))
            #expect(Array(rip.samples[sector]) == Array(samples[sector]))
        } else {
            // The sector alternates on every read from the disc, so nothing decides it.
            #expect(rip.status == .suspect)
            #expect(rip.unresolvedSectors == [700] && rip.versionCounts[700] == 2)
        }
    }

    /// A sector that fails to read is not silence: it has no version until a read gets
    /// it, and one such read is not enough to decide it.
    @Test(arguments: [false, true])
    func readsAnUnreadableSectorAgainLater(withRecords: Bool) throws {
        let (toc, samples, record) = try TrackRipperTests().disc()
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: Self.driveOffset)
        // The first read's chunk and its two tries fail; the next read works.
        drive.failingReads = [600: 3]
        var reader = AudioReader(drive: drive, toc: toc, readOffset: Self.driveOffset, canOverread: false)
        reader.unreadableRetries = 1
        var secure = SecureRipper(ripper: TrackRipper(reader: reader, records: withRecords ? [record] : []))
        secure.cacheFlushSectors = toc.leadOutLBA
        let track = toc.tracks[1]
        let rip = try secure.rip(track)
        // Drive sector 600, at offset +667, holds the end of sector 138 and most of 139.
        #expect(rip.unreadableSectors == [138, 139])
        #expect(rip.status == (withRecords ? .accurate(v1Confidence: 0, v2Confidence: 4) : .consistent))
        #expect(rip.unresolvedSectors.isEmpty)
        #expect(rip.samples[...] == trueSamples(of: track, in: toc, samples))
        if !withRecords { #expect(rip.rounds == 1 && rip.versionCounts == [138: 1, 139: 1]) }
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
            let whole = AccurateRipAccumulator.checksum(of: samples[...], isFirstTrack: first, isLastTrack: last)
            var sum = AccurateRipChecksum.zero
            for start in stride(from: 0, to: samples.count, by: 588) {
                let part = Array(samples[start..<(start + 588)])
                sum =
                    sum
                    + AccurateRipAccumulator.contribution(
                        of: part[...], at: start + 1, sampleCount: samples.count, isFirstTrack: first, isLastTrack: last
                    )
            }
            #expect(sum == whole)
        }
    }
}
