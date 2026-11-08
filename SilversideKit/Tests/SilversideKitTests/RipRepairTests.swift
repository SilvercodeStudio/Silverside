import Foundation
import Testing

@testable import SilversideKit

struct RipRepairTests {
    /// A rip made offline, with a sector that reads wrong every time: the repair fixes it
    /// with CTDB's data, and the repaired folder gets a report that says so, which the
    /// encoder reads as a verified rip.
    @Test func writesAReportIntoTheRepairedFolder() async throws {
        let (toc, samples) = try makeDisc(trackSectors: [800, 900])
        let (result, _, _, root) = try await DiscRipTests().rip { $0.corruptSectors = [1000] }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(result.report.ctdb.status == .notChecked)
        var repair = RipRepair(toc: toc, folders: [result.folder])
        repair.webClient = await DiscRipTests.web(toc: toc, samples: samples).client(in: root.appending(path: "cache"))
        let events = RipRepairEvents()
        repair.events = { events.append($0) }
        let outcome = try await repair.run()
        guard case .repaired = outcome.outcome else {
            Issue.record("Expected a repair, got \(outcome.outcome)")
            return
        }
        let written = try RipReport.read(from: repair.output.appending(path: "disc.json"))
        #expect(written.ctdb.status == .repaired)
        #expect(written.tracks.map(\.accurateRip) == [.accurate, .accurate])
        #expect(written.tracks.map(\.repairedSamples) == [0, 588])
        #expect(written.tracks.map(\.ctdbConfidence) == [5, 5])
        #expect(written.isVerified)
        #expect(written.files == ["Rip Report.log", "Rip Report.md", "Track 01.wav", "Track 02.wav", "disc.json"])
        #expect(FileManager.default.fileExists(atPath: repair.output.appending(path: "Rip Report.md").path))
        let disc = try RippedDisc(folder: repair.output)
        #expect(disc.tracks.allSatisfy { $0.isVerified })
        #expect(events.list.contains { if case .reportWritten(repair.output) = $0 { true } else { false } })
        // The rip's own report is as it was.
        #expect(try RipReport.read(from: result.folder.appending(path: "disc.json")).ctdb.status == .notChecked)
    }

    /// With the disc in a drive, a re-read of a track that loses its place (from its sector
    /// 1,050 on, the audio 50 sectors further on) is left out, not kept, and read again; the
    /// repair still fixes the track. A kept read that lost its place is left out of the pool.
    @Test func leavesOutAReadThatLostItsPlace() async throws {
        let (toc, samples) = try makeDisc(trackSectors: [800, 900])
        let (result, _, _, root) = try await DiscRipTests().rip { $0.corruptSectors = [1000] }
        defer { try? FileManager.default.removeItem(at: root) }
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: 6)
        drive.corruptSectors = [1000]
        drive.slips = [.init(sector: 1050, shift: 50 * 588, onPass: 1)]
        var repair = RipRepair(toc: toc, folders: [result.folder])
        repair.reader = AudioReader(drive: drive, toc: toc, readOffset: 6, canOverread: false)
        repair.cacheFlushSectors = 64
        repair.webClient = await DiscRipTests.web(toc: toc, samples: samples).client(in: root.appending(path: "cache"))
        let events = RipRepairEvents()
        repair.events = { events.append($0) }
        let outcome = try await repair.run()
        guard case .repaired = outcome.outcome else {
            Issue.record("Expected a repair, got \(outcome.outcome)")
            return
        }
        #expect(events.list.contains { if case .rereadLostItsPlace(2) = $0 { true } else { false } })
        let kept = RipRepair.readFolders(after: result.folder).map { $0.appending(path: "Track 02.wav") }
        #expect(kept.count == 2)
        let ripped = try WAVFile.read(result.folder.appending(path: "Track 02.wav"))
        for file in kept { #expect(try !RipPool.lostItsPlace(WAVFile.read(file), against: ripped)) }

        // A read kept from before this check, that lost its place, does not join the pool.
        var lost = ripped
        lost.replaceSubrange((250 * 588)..<(850 * 588), with: ripped[(300 * 588)..<(900 * 588)])
        try WAVFile.write(lost, to: kept[0])
        let track = toc.audioTracks[1]
        let pooled = RipPool.versions(
            of: track, toc: toc, in: [result.folder] + RipRepair.readFolders(after: result.folder))
        #expect(pooled.versions.count == 2 && pooled.skipped.map(\.url) == [kept[0]])
    }

    /// A rip whose own copy of a track lost its place: the repair's reads of the disc agree
    /// with each other, outvote it, and the repair fixes the track from them.
    @Test func outvotesARipThatLostItsPlace() async throws {
        let (toc, samples) = try makeDisc(trackSectors: [800, 900])
        let (result, _, _, root) = try await DiscRipTests().rip { $0.corruptSectors = [1000] }
        defer { try? FileManager.default.removeItem(at: root) }
        let file = result.folder.appending(path: "Track 02.wav")
        var ripped = try WAVFile.read(file)
        ripped.replaceSubrange((300 * 588)..<(800 * 588), with: ripped[(340 * 588)..<(840 * 588)])
        try WAVFile.write(ripped, to: file)
        // Its suspects go with it.
        var suspects = TrackAudio(samples: ripped)
        for sample in (300 * 588)..<(350 * 588) { suspects.alternatives[sample] = [0] }
        try suspects.writeAlternatives(to: result.folder.appending(path: "Track 02.suspects"))
        let drive = SimulatedDrive(toc: toc, samples: samples, readOffset: 6)
        drive.corruptSectors = [1000]
        var repair = RipRepair(toc: toc, folders: [result.folder])
        repair.reader = AudioReader(drive: drive, toc: toc, readOffset: 6, canOverread: false)
        repair.cacheFlushSectors = 64
        repair.webClient = await DiscRipTests.web(toc: toc, samples: samples).client(in: root.appending(path: "cache"))
        let events = RipRepairEvents()
        repair.events = { events.append($0) }
        let outcome = try await repair.run()
        guard case .repaired = outcome.outcome else {
            Issue.record("Expected a repair, got \(outcome.outcome)")
            return
        }
        #expect(
            events.list.contains {
                if case .repairLog(let line) = $0 { line.contains("an earlier version lost its place") } else { false }
            })
        #expect(outcome.samples(ofTrack: 1).dropLast(6) == samples[(800 * 588)...].dropLast(6))
        #expect(
            events.list.contains {
                if case .trackPooled(2, _, let suspectSamples) = $0 { suspectSamples == 0 } else { false }
            })
    }

    /// The pool decides which reads lost their place by agreement, or by AccurateRip, not by
    /// which comes first: a first version that lost its place loses to two that agree, and to
    /// one that AccurateRip proves. The suspects beside a read left out are left out too, and
    /// so is a suspects file that marks most of the track.
    @Test func poolsTheReadsThatAgreeWhicheverComesFirst() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SilversideTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (toc, samples) = try makeDisc(trackSectors: [800, 900])
        let track = toc.audioTracks[1]
        let good = Array(samples[(800 * 588)..<(1700 * 588)])
        var lost = good
        lost.replaceSubrange((100 * 588)..<(800 * 588), with: good[(150 * 588)..<(850 * 588)])
        let folders = ["lost", "good", "good again"].map { root.appending(path: $0, directoryHint: .isDirectory) }
        for (folder, audio) in zip(folders, [lost, good, good]) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try WAVFile.write(audio, to: folder.appending(path: "Track 02.wav"))
        }
        // The lost read's suspects: nearly the whole track, as a repair once saved them.
        try TrackAudio(versions: [lost, good]).writeAlternatives(to: folders[0].appending(path: "Track 02.suspects"))
        let agreeing = RipPool.versions(of: track, toc: toc, in: folders)
        #expect(agreeing.versions == [good, good])
        #expect(agreeing.alternatives.isEmpty)
        #expect(Set(agreeing.skipped.map(\.url.lastPathComponent)) == ["Track 02.wav", "Track 02.suspects"])
        // One good read, after the lost one: AccurateRip decides.
        let records = try AccurateRipRecord.records(
            from: [UInt8](DiscRipTests.accurateRipFile(toc: toc, samples: samples)))
        let proved = RipPool.versions(of: track, toc: toc, in: Array(folders.prefix(2)), records: records)
        #expect(proved.versions == [good])
        // Without AccurateRip, the first of two that disagree stands, as before.
        #expect(RipPool.versions(of: track, toc: toc, in: Array(folders.prefix(2))).versions == [lost])
        // A suspects file beside a good read that marks most of the track is left out.
        try TrackAudio(versions: [lost, good]).writeAlternatives(to: folders[1].appending(path: "Track 02.suspects"))
        let marked = RipPool.versions(of: track, toc: toc, in: Array(folders.suffix(2)))
        #expect(marked.versions.count == 2 && marked.alternatives.isEmpty && marked.skipped.count == 1)
    }

    /// A rip that CTDB verifies as it is: nothing is written next to it, and its own report
    /// says it is verified from now on.
    @Test func updatesTheReportOfAVerifiedRip() async throws {
        let (toc, samples) = try makeDisc(trackSectors: [800, 900])
        let (result, _, _, root) = try await DiscRipTests().rip()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!result.report.isVerified)
        var repair = RipRepair(toc: toc, folders: [result.folder])
        repair.webClient = await DiscRipTests.web(toc: toc, samples: samples).client(in: root.appending(path: "cache"))
        let outcome = try await repair.run()
        guard case .verified = outcome.outcome else {
            Issue.record("Expected verified, got \(outcome.outcome)")
            return
        }
        let updated = try RipReport.read(from: result.folder.appending(path: "disc.json"))
        #expect(updated.ctdb.status == .verified && updated.isVerified)
        #expect(updated.tracks.map(\.ctdbConfidence) == [5, 5])
        #expect(!FileManager.default.fileExists(atPath: repair.output.path))
    }
}

/// The events of a repair, in order, from whichever thread sends them.
final class RipRepairEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events = [RipRepairEvent]()

    func append(_ event: RipRepairEvent) {
        lock.withLock { events.append(event) }
    }

    var list: [RipRepairEvent] { lock.withLock { events } }
}
