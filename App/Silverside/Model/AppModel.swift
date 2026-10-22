import AppKit
import Foundation
import Observation
import SilversideDarwin
import SilversideKit

/// What the sidebar can select: a drive, or an earlier rip.
enum SidebarItem: Hashable {
    case drive(String)
    case rip(URL)
    /// Every earlier rip, in a table.
    case history
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// The app's state: the settings, the drives and their discs, and the earlier rips.
@Observable
final class AppModel {
    /// The settings file that `silverside config` shares. A change saves at once.
    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            do {
                try settings.save()
            } catch {
                alert = AppAlert(title: "The settings could not be saved", message: "\(error)")
            }
            if settings.rips != oldValue.rips || settings.library != oldValue.library { refreshRecentRips() }
        }
    }
    private(set) var drives: [DriveSlot] = []
    private(set) var recentRips: [RecentRip] = []
    var selection: SidebarItem?
    var alert: AppAlert?
    /// True while a sheet or panel shows the rip's log.
    var logShown = false
    /// The repair under way, or the last one, shown in a sheet.
    private(set) var repair: RepairRun?
    var repairShown = false

    @ObservationIgnored private var watcher: DiskWatcher?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init() {
        settings = (try? Settings.load()) ?? Settings()
        #if DEBUG
            // `-demo` adds a simulated drive with a disc, offline; `-demoRip` starts its rip.
            if UserDefaults.standard.bool(forKey: "demo"), let demo = DemoDisc.slot() {
                drives.append(demo)
                if UserDefaults.standard.bool(forKey: "demoRip") {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1))
                        startRip(demo)
                    }
                }
            }
        #endif
        refreshDrives()
        refreshRecentRips()
        if selection == nil { selection = drives.first.map { .drive($0.id) } }
        watcher = DiskWatcher { [weak self] in self?.discsChanged() }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDrives() }
            })
    }

    /// The drive that the sidebar selects, if any.
    var selectedDrive: DriveSlot? {
        guard case .drive(let id) = selection else { return nil }
        return drives.first { $0.id == id }
    }

    var selectedRip: RecentRip? {
        guard case .rip(let url) = selection else { return nil }
        return recentRips.first { $0.file == url }
    }

    /// The earlier rips of a disc that still have their audio, by its TOC: the pool for a new rip or a repair.
    func earlierRips(of tocString: String) -> [RecentRip] {
        recentRips.filter { $0.hasAudio && $0.report.toc == tocString }
    }

    /// The multi-disc releases among the earlier rips, with the discs ripped so far.
    var sets: [RipSet] { RipSet.sets(in: recentRips.map { ($0.folder, $0.report) }) }

    func set(for release: MusicBrainzRelease?) -> RipSet? {
        guard let release, release.media.count > 1 else { return nil }
        return sets.first { $0.releaseID == release.id }
    }

    // MARK: Drives

    /// Lists the drives again. A drive that is still there keeps its state; a disc that
    /// came or went is read, or forgotten.
    func refreshDrives() {
        #if DEBUG
            // `-demoOnly` leaves the real drives alone, for work on the app with a disc in one.
            if UserDefaults.standard.bool(forKey: "demoOnly") { return }
        #endif
        let devices = OpticalDrive.all()
        var slots = drives.filter(\.isDemo)
        var seen = [String: Int]()
        for device in devices {
            let base = DriveSlot.baseID(of: device)
            let count = seen[base, default: 0]
            seen[base] = count + 1
            let id = count == 0 ? base : "\(base) #\(count + 1)"
            if let existing = drives.first(where: { $0.id == id }) {
                existing.update(device)
                slots.append(existing)
            } else {
                slots.append(DriveSlot(id: id, device: device))
            }
        }
        drives = slots
        for slot in drives where slot.needsDisc { slot.readDisc(settings: settings) }
    }

    private func discsChanged() {
        // A disc that just appeared is not yet the console user's: give cddafs a moment.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            refreshDrives()
        }
    }

    func eject(_ slot: DriveSlot) {
        guard let bsdName = slot.device.discBSDName else { return }
        Task { @MainActor in
            do {
                try await DiscEject.eject(bsdName: bsdName)
                refreshDrives()
            } catch {
                alert = AppAlert(title: "The disc could not be ejected", message: "\(error)")
            }
        }
    }

    // MARK: Rips

    func startRip(_ slot: DriveSlot) {
        guard slot.rip?.isRunning != true, !slot.isBusy, let disc = slot.disc else { return }
        var options = DiscRipOptions(settings: settings)
        options.folder = slot.choices.folder
        options.offline = slot.choices.offline
        options.release = disc.release
        options.cover = disc.userCover
        if slot.choices.poolsEarlierRips {
            options.pool = earlierRips(of: disc.toc.ctdbTOCString).map(\.folder)
        }
        let selected = slot.selectedTracks
        if selected.count != disc.toc.audioTracks.count {
            options.tracks = disc.toc.audioTracks.map(\.number).filter { selected.contains($0) }
        }
        options.releaseID = disc.release?.id
        options.edits = disc.edits.isEmpty ? nil : disc.edits
        options.manualRelease = disc.manual
        options.singlePass = slot.fastMode
        if slot.isDemo {
            options.offline = true
            options.readOffset = 6
            options.folder = URL.temporaryDirectory.appending(path: "Silverside Demo \(UUID().uuidString)")
        }
        let run = RipRun(disc: disc)
        slot.rip = run
        run.onProgress = { [weak self] in self?.updateDock() }
        run.start(
            makeDrive: slot.makeDrive, identity: slot.identity, settings: settings, options: options,
            encodes: settings.encodeAfterRip && !slot.isDemo
        ) { [weak self] in
            guard let self else { return }
            updateDock()
            refreshRecentRips()
            RipNotifier.ripFinished(title: notificationTitle(for: run), body: run.statusText)
            if settings.ejectAfterRip, run.result?.report.isVerified == true, !slot.isDemo { eject(slot) }
        }
    }

    private func notificationTitle(for run: RipRun) -> String {
        switch run.phase {
        case .finished: "\(run.disc.title) ripped"
        case .stopped: "\(run.disc.title): rip stopped"
        default: "\(run.disc.title): rip failed"
        }
    }

    /// The Dock tile shows the running rips' progress, as one bar.
    private func updateDock() {
        let running = drives.compactMap(\.rip).filter(\.isRunning)
        let fractions = running.map { $0.phase == .encoding ? $0.encodeFraction : $0.fraction }
        DockProgress.show(running.isEmpty ? nil : fractions.reduce(0, +) / Double(running.count))
    }

    func stopRip(_ slot: DriveSlot) {
        slot.rip?.stop()
    }

    // MARK: Repairs

    /// Repairs an earlier rip with CTDB's data, pooled with the other rips of the disc,
    /// and with re-reads when the disc is in a drive that is free.
    func startRepair(_ rip: RecentRip) {
        guard repair?.isRunning != true else {
            repairShown = true
            return
        }
        let pool = earlierRips(of: rip.report.toc).map(\.folder).filter { $0 != rip.folder }
        let slot = drives.first {
            !$0.isDemo && !$0.isBusy && $0.rip?.isRunning != true && $0.disc?.toc.ctdbTOCString == rip.report.toc
        }
        let run = RepairRun(rip: rip, pool: pool, drive: slot)
        repair = run
        repairShown = true
        run.start { [weak self] in
            guard let self else { return }
            refreshRecentRips { [weak self] in
                // The repaired rip, or the rip with its new report, is what to look at now.
                if let folder = run.reportFolder { self?.selection = .rip(folder.appending(path: "disc.json")) }
            }
        }
    }

    // MARK: Earlier rips

    func refreshRecentRips(then completion: (@MainActor () -> Void)? = nil) {
        let folder = settings.ripsURL
        let library = settings.libraryURL
        Task.detached(priority: .utility) {
            let rips = RecentRip.scan(rips: folder, library: library)
            await MainActor.run {
                self.recentRips = rips
                completion?()
            }
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealFolder(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
