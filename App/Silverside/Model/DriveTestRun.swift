import AppKit
import Foundation
import Observation
import SilversideDarwin
import SilversideKit

/// A check of a drive with the disc in it (`silverside drives --report`), or a measurement of
/// its cache (`--measure-cache`), from Settings › Drives.
@Observable
final class DriveTestRun: Identifiable {
    enum Kind {
        case test
        case cache
    }

    let id = UUID()
    let kind: Kind
    let slot: DriveSlot
    private(set) var log: [String] = []
    private(set) var report: DriveReport?
    private(set) var cacheSectors: Int?
    private(set) var isRunning = true
    private(set) var error: String?

    init(kind: Kind, slot: DriveSlot) {
        self.kind = kind
        self.slot = slot
    }

    var title: String { kind == .test ? "Drive Test" : "Cache Measurement" }

    /// Starts the checks on a thread of their own. A measured cache size goes into the drive's profile.
    func start(profile: DriveProfile, onFinish: @escaping @MainActor () -> Void) {
        let makeDrive = slot.makeDrive
        let registry = slot.device.registry
        let kind = self.kind
        let isDemo = slot.isDemo
        let run = self
        slot.isBusy = true
        add(
            kind == .test
                ? "Checking \(slot.name) with the disc in it. The checks take about 20 seconds."
                : "Measuring the cache of \(slot.name) with timed reads. This can take a minute.")
        Task.detached {
            @Sendable func onMain(_ body: @escaping @MainActor () -> Void) {
                DispatchQueue.main.async { MainActor.assumeIsolated(body) }
            }
            do {
                let drive = try makeDrive()
                switch kind {
                case .test:
                    var report = DriveReport(registry: registry, profile: profile)
                    report.check(drive) { name in onMain { run.add("  \(name)...") } }
                    let finished = report
                    onMain {
                        run.report = finished
                        run.finish(error: nil)
                        onFinish()
                    }
                case .cache:
                    let sectors = try CacheProbe(drive: drive).cacheSectors(toc: drive.readTOC())
                    if let sectors, !isDemo {
                        var changed = profile
                        changed.cacheSectors = sectors
                        var store = try DriveProfileStore()
                        try store.save(changed)
                    }
                    onMain {
                        run.cacheSectors = sectors
                        run.finish(
                            error: sectors == nil
                                ? "No cache size found: reads stayed fast, or the disc is too short." : nil
                        )
                        onFinish()
                    }
                }
            } catch {
                onMain {
                    run.finish(error: "\(error)")
                    onFinish()
                }
            }
        }
    }

    private func finish(error: String?) {
        self.error = error
        isRunning = false
        slot.isBusy = false
        if let error {
            add("Failed: \(error)")
        } else if let report {
            let failed = report.checks.filter { !$0.passed }.count
            add(failed == 0 ? "Every check passed." : "\(Format.count(failed, "check")) failed.")
        } else if let cacheSectors {
            add(
                cacheSectors <= CacheProbe(timedRead: { _, _ in .zero }).precision
                    ? "The drive keeps only the latest read (\(cacheSectors) sectors or fewer)."
                    : "Cache: about \(cacheSectors) sectors.")
            if !slot.isDemo { add("Saved in the drive's profile.") }
        }
    }

    private func add(_ line: String) {
        log.append(line)
    }

    /// Saves the report as JSON, for a bug report.
    func saveReport() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = NameTemplate.safeComponent("Silverside Drive Report \(slot.name)") + ".json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.write(to: url)
            add("Report: \(url.path)")
        } catch {
            add("The report could not be saved: \(error)")
        }
    }
}
