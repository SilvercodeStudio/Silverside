import CDRipDarwin
import CDRipKit
import Foundation
import Observation

/// A repair of an earlier rip, as `cdrip repair` does it: the rip pools with the other
/// rips of the disc, and the disc is read again when it is in a drive. The engine's
/// events become a log, and the outcome a headline.
@Observable
final class RepairRun: Identifiable {
    enum Phase: Equatable {
        case running
        case finished
        case stopped
        case failed(String)
    }

    let id = UUID()
    let rip: RecentRip
    /// The other rips of the disc that join the pool.
    let pool: [URL]
    /// The drive that holds the disc, for re-reads. Nil when the disc is not in a drive.
    let drive: DriveSlot?
    private(set) var phase = Phase.running
    private(set) var log: [String] = []
    private(set) var outcome: DiscRepairer.Outcome?
    private(set) var repairedSamples = 0
    /// The folder with the repaired files, when the repair changed the rip.
    private(set) var writtenFolder: URL?
    /// The folder whose report the repair wrote: the repaired folder, or the rip's own when it was verified.
    private(set) var reportFolder: URL?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(rip: RecentRip, pool: [URL], drive: DriveSlot?) {
        self.rip = rip
        self.pool = pool
        self.drive = drive
    }

    var isRunning: Bool { phase == .running }

    /// What the repair found, in a line.
    var headline: String {
        switch phase {
        case .running: return "Repairing..."
        case .stopped: return "Stopped. Nothing was written."
        case .failed(let message): return "The repair failed: \(message)"
        case .finished:
            switch outcome {
            case .verified(let entry, _):
                return
                    "Verified: the rip matches CTDB entry \(entry.id) (\(entry.confidence) submissions) with no errors."
            case .repaired:
                return "Repaired \(repairedSamples.formatted()) samples. The repaired rip is in a folder of its own."
            case .partlyRepaired(_, _, let tracks, _):
                return
                    "Repaired \(tracks.count == 1 ? "track" : "tracks") \(tracks.map(String.init).joined(separator: ", ")); the other tracks still have errors."
            case .notVerified:
                return "Could not verify or repair the rip with any CTDB entry."
            case nil:
                return "Done."
            }
        }
    }

    /// Starts the repair on a thread of its own. The engine's events come back on the main queue, in order.
    func start(onFinish: @escaping @MainActor () -> Void) {
        guard let toc = try? TOC(ctdbTOCString: rip.report.toc) else {
            phase = .failed("The rip's TOC cannot be read.")
            return
        }
        let folders = [rip.folder] + pool
        add("Rip: \(rip.folder.path)")
        for folder in pool { add("Pooled with: \(folder.path)") }
        let makeDrive = drive?.makeDrive
        let identity = drive?.identity
        if drive == nil { add("The disc is not in a drive, so the repair uses the rips' files only.") }
        drive?.isBusy = true
        let run = self
        task = Task.detached {
            @Sendable func onMain(_ body: @escaping @MainActor () -> Void) {
                DispatchQueue.main.async { MainActor.assumeIsolated(body) }
            }
            do {
                var repair = RipRepair(toc: toc, folders: folders)
                if let makeDrive, let identity {
                    let profile = try DriveProfileStore().profile(
                        vendor: identity.vendor, product: identity.product, revision: identity.revision)
                    if let offset = profile.offset?.value {
                        var reader = AudioReader(
                            drive: try makeDrive(), toc: toc, readOffset: offset, canOverread: false)
                        reader.unreadableRetries = 3
                        repair.reader = reader
                        repair.cacheFlushSectors = profile.cacheFlushSectors
                        onMain { run.add("Re-reads in \(identity.name), read offset \(offset.signedDescription).") }
                    } else {
                        onMain {
                            run.add("The read offset of \(identity.name) is not known, so the disc is not read again.")
                        }
                    }
                }
                repair.events = { event in onMain { run.handle(event) } }
                _ = try await repair.run()
                onMain {
                    run.end(.finished)
                    onFinish()
                }
            } catch is CancellationError {
                onMain {
                    run.end(.stopped)
                    onFinish()
                }
            } catch {
                onMain {
                    run.add("Failed: \(error)")
                    run.end(.failed("\(error)"))
                    onFinish()
                }
            }
        }
    }

    /// Stops after the read under way. Nothing is written.
    func stop() {
        guard isRunning else { return }
        add("Stopping after the read under way...")
        task?.cancel()
    }

    private func end(_ phase: Phase) {
        self.phase = phase
        drive?.isBusy = false
        add(headline)
    }

    private func add(_ line: String) {
        log.append(line)
    }

    private func handle(_ event: RipRepairEvent) {
        switch event {
        case .trackAccurate(let number):
            add(String(format: "Track %2d  accurate in AccurateRip", number))
        case .trackMatchesOtherPressing(let number, let shift):
            add(
                String(format: "Track %2d  free of errors: matches another pressing at ", number)
                    + shift.signedDescription)
        case .trackPooled(let number, let versions, let suspectSamples):
            add(
                String(format: "Track %2d  ", number)
                    + "\(Format.count(versions, "version")), \(suspectSamples) samples where they disagree")
        case .poolFileSkipped(let file):
            add("\(file.url.lastPathComponent) was not used: \(file.reason).")
        case .ctdbEntries(let count, let mostSubmissions):
            add("CTDB: \(Format.count(count, "entry")), up to \(mostSubmissions) submissions")
        case .repairLog(let line):
            add(line)
        case .finished(let result):
            outcome = result.outcome
            if result.entriesWithoutRepairData > 0 {
                add(
                    "\(result.entriesWithoutRepairData) more entries match the rip's alignment, but have no repair data."
                )
            }
        case .writing(let folder, let repairedSamples):
            writtenFolder = folder
            self.repairedSamples = repairedSamples
            add("Repaired \(repairedSamples) samples. Files: \(folder.path)")
        case .trackWritten(let number, let repairedSamples, let accurateRip):
            var line = String(format: "  Track %2d  %6d samples repaired  ", number, repairedSamples)
            switch accurateRip {
            case .accurate(let v1, let v2): line += "AccurateRip: accurate (v1 \(v1), v2 \(v2))"
            case .notAccurate: line += "AccurateRip: not accurate"
            case .notChecked: line += "AccurateRip: not in the database"
            }
            add(line)
        case .reportWritten(let folder):
            reportFolder = folder
            add("Report: \(folder.appending(path: "disc.json").path)")
        }
    }
}
