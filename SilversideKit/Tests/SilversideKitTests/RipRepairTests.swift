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
