import Foundation
import Testing

@testable import SilversideKit

struct DiscRepairerTests {
    /// A CTDB entry for `audio` at `shift`, and its repair data.
    func entry(for audio: [UInt32], toc: TOC, shift: Int = 0, count: Int = 16) -> (CTDBEntry, [UInt16]) {
        let layout = CTDBLayout(toc: toc)
        let syndromes = CTDB.syndromes(of: audio, layout: layout, shift: shift, count: count)
        let entry = CTDBEntry(
            id: 1, confidence: 5, crc32: CTDB.discCRC(of: audio, layout: layout, shift: shift),
            trackCRCs: CTDB.trackCRCs(of: audio, toc: toc, layout: layout, shift: shift),
            repairDataURL: URL(string: "https://example.org/parity"), syndromeCount: count,
            column0Syndromes: Array(syndromes[0..<count]))
        return (entry, syndromes)
    }

    func tracks(of samples: [UInt32], toc: TOC) -> [TrackAudio] {
        toc.audioTracks.map { track in
            let sectors = toc.sectorRange(of: track)
            return TrackAudio(samples: Array(samples[(sectors.lowerBound * 588)..<(sectors.upperBound * 588)]))
        }
    }

    @Test func verifiesARipWithNoErrors() async throws {
        let (toc, samples, record) = try TrackRipperTests().disc()
        let (entry, _) = entry(for: samples, toc: toc)
        let repairer = DiscRepairer(toc: toc, records: [record], entries: [entry])
        let result = try await repairer.repair(tracks(of: samples, toc: toc))
        #expect(result.outcome == .verified(entry: entry, shift: 0))
        #expect(result.trackConfidences == [5, 5, 5])
    }

    /// Entries can be stored at another pressing's alignment. The check finds that with no repair.
    @Test func verifiesAtAnotherShift() async throws {
        let (toc, samples, record) = try TrackRipperTests().disc()
        let (entry, _) = entry(for: samples, toc: toc, shift: 1195)
        var repairer = DiscRepairer(toc: toc, records: [record], entries: [entry])
        repairer.repairData = { _ in
            Issue.record("A check needs no repair data")
            return []
        }
        let result = try await repairer.repair(tracks(of: samples, toc: toc), repairing: false)
        #expect(result.outcome == .verified(entry: entry, shift: 1195))
    }

    @Test func onlyChecksWhenNotRepairing() async throws {
        let (toc, samples, record) = try TrackRipperTests().disc()
        let (entry, _) = entry(for: samples, toc: toc)
        var damaged = samples
        damaged[300_000] ^= 1
        var repairer = DiscRepairer(toc: toc, records: [record], entries: [entry])
        repairer.repairData = { _ in
            Issue.record("A check needs no repair data")
            return []
        }
        let result = try await repairer.repair(tracks(of: damaged, toc: toc), repairing: false)
        #expect(result.outcome == .notVerified)
        #expect(result.audio == damaged)
        #expect(result.trackConfidences == [5, 0, 5])
    }

    /// An entry with more syndromes than Silverside uses is left out, and the others still work.
    @Test func leavesOutAnEntryWithTooManySyndromes() async throws {
        let (toc, samples, record) = try TrackRipperTests().disc()
        var damaged = samples
        damaged[300_000] ^= 1
        let (good, syndromes) = entry(for: samples, toc: toc)
        var big = good
        big.id = 2
        big.confidence = 99
        big.syndromeCount = 32
        big.column0Syndromes = [UInt16](repeating: 1, count: 32)
        var repairer = DiscRepairer(toc: toc, records: [record], entries: [big, good])
        repairer.repairData = { _ in syndromes }
        let result = try await repairer.repair(tracks(of: damaged, toc: toc))
        #expect(result.outcome == .repaired(entry: good, shift: 0, changedSamples: [300_000]))
    }

    @Test func refusesPartOfADisc() async throws {
        let (toc, samples, record) = try TrackRipperTests().disc()
        let (entry, _) = entry(for: samples, toc: toc)
        let repairer = DiscRepairer(toc: toc, records: [record], entries: [entry])
        await #expect(throws: DiscRepairError.incompleteAudio) {
            try await repairer.repair(Array(tracks(of: samples, toc: toc).prefix(2)))
        }
    }

    /// An error that reads the same every time: the secure ripper cannot see it, and the repair data corrects it.
    @Test func repairsAConsistentErrorAfterASecureRip() async throws {
        let (secure, toc, samples, _) = try SecureRipperTests().setUp(corrupt: [600])
        let rips = try toc.audioTracks.map { try secure.rip($0) }
        #expect(rips[1].status == .consistentButNotAccurate)
        let (entry, syndromes) = entry(for: samples, toc: toc)
        var repairer = DiscRepairer(toc: toc, records: secure.ripper.records, entries: [entry])
        repairer.repairData = { _ in syndromes }
        let result = try await repairer.repair(rips.map(TrackAudio.init))
        guard case .repaired(_, 0, let changed) = result.outcome else {
            Issue.record("Not repaired: \(result.outcome)")
            return
        }
        #expect(changed.count == 588)
        // Without overread, the rip ends in silence where the drive's offset passes the
        // lead-out. CTDB leaves out the last row, so it does not see that.
        #expect(result.audio.dropLast(SecureRipperTests.driveOffset) == samples.dropLast(SecureRipperTests.driveOffset))
        #expect(result.changedSamples(inTrack: 1) == 588 && result.changedSamples(inTrack: 0) == 0)
    }

    /// Four damaged sectors at the same place in four rows give each of their columns 4
    /// errors: too many for 6 syndromes at unknown places, but not when the secure rip
    /// has marked them as suspect.
    @Test func repairsWithTheSecureRipsSuspects() async throws {
        let unstable: Set<Int> = [500, 510, 520, 530]
        let (secure, toc, samples, _) = try SecureRipperTests().setUp(unstable: unstable, withRecords: false)
        var rips = try toc.audioTracks.map { try secure.rip($0) }
        #expect(Set(rips[1].suspectSectors.map { $0 + 460 }) == unstable)
        // As if the reads had given the wrong version of each sector most often.
        for (sector, versions) in rips[1].sectorVersions {
            let range = (sector * 588)..<((sector + 1) * 588)
            let truth = Array(samples[((460 * 588) + range.lowerBound)..<((460 * 588) + range.upperBound)])
            rips[1].samples.replaceSubrange(range, with: versions.first { $0 != truth }!)
        }
        let (entry, syndromes) = entry(for: samples, toc: toc, count: 6)
        var repairer = DiscRepairer(toc: toc, records: [], entries: [entry])
        repairer.repairData = { _ in syndromes }

        let blind = try await repairer.repair(rips.map { TrackAudio(samples: $0.samples) })
        #expect(blind.outcome == .notVerified)
        let result = try await repairer.repair(rips.map(TrackAudio.init))
        guard case .repaired(_, 0, let changed) = result.outcome else {
            Issue.record("Not repaired: \(result.outcome)")
            return
        }
        #expect(changed.count == 4 * 588)
        #expect(result.audio.dropLast(SecureRipperTests.driveOffset) == samples.dropLast(SecureRipperTests.driveOffset))
    }

    /// The first track matches another pressing, 30 samples later. Its audio before the
    /// disc's start is silence, which AccurateRip skips.
    @Test func findsAnotherPressingForTheFirstTrack() throws {
        let (toc, samples, _) = try TrackRipperTests().disc()
        let length = 460 * 588
        let pressing = [UInt32](repeating: 0, count: 30) + samples.dropLast(30)
        let checksum = AccurateRipAccumulator.checksum(
            of: Array(pressing[0..<length])[...], isFirstTrack: true, isLastTrack: false)
        let sector450 = Array(pressing[(450 * 588)..<(451 * 588)])
        let frame450 = AccurateRipAccumulator.checksum(of: sector450[...], isFirstTrack: false, isLastTrack: false)
        let known = [AccurateRipRecord.Track(confidence: 2, checksum: checksum.v2, frame450Checksum: frame450.v1)]
        #expect(toc.audioTracks[0].startLBA == 0)
        #expect(
            DiscRepairer.otherPressingShift(
                of: samples, start: 0, length: length, edges: (true, false), known: known) == -30)
    }

    @Test func choosesTheMostFrequentValue() {
        let audio = TrackAudio(versions: [[1, 2, 3, 4], [1, 5, 3, 6], [1, 5, 7, 8]])
        #expect(audio.samples == [1, 5, 3, 4])
        #expect(audio.alternatives == [1: [2], 2: [7], 3: [6, 8]])
    }

    @Test func keepsAlternativesInAFile() throws {
        let audio = TrackAudio(samples: [1, 2, 3], alternatives: [0: [7], 2: [0xFFFF_FFFF, 9]])
        let url = FileManager.default.temporaryDirectory.appending(path: "suspects-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        try audio.writeAlternatives(to: url)
        #expect(try TrackAudio.readAlternatives(from: url) == audio.alternatives)
        try Data([1, 2, 3, 4]).write(to: url)
        #expect(throws: CocoaError.self) { try TrackAudio.readAlternatives(from: url) }
    }

    @Test func addsOnlyNewValues() {
        var audio = TrackAudio(samples: [1, 2, 3], alternatives: [0: [7]])
        audio.add([0: [7, 8, 1], 1: [2], 2: [4], 5: [6]])
        #expect(audio.alternatives == [0: [7, 8], 2: [4]])
    }

    @Test func groupsConsecutiveSamples() {
        #expect(DiscRepairer.ranges(of: [1, 2, 3, 5, 7, 8]) == [1..<4, 5..<6, 7..<9])
    }
}
