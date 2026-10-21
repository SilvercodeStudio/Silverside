import AppKit
import CDRipDarwin
import CDRipKit
import Foundation
import Observation

/// What the sidebar can select: a drive, or an earlier rip.
enum SidebarItem: Hashable {
    case drive(String)
    case rip(URL)
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// The app's state: the settings, the drives and their discs, and the earlier rips.
@Observable
final class AppModel {
    /// The settings file that `cdrip config` shares. A change saves at once.
    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            do {
                try settings.save()
            } catch {
                alert = AppAlert(title: "The settings could not be saved", message: "\(error)")
            }
            if settings.rips != oldValue.rips { refreshRecentRips() }
        }
    }
    private(set) var drives: [DriveSlot] = []
    private(set) var recentRips: [RecentRip] = []
    var selection: SidebarItem?
    var alert: AppAlert?
    /// True while a sheet or panel shows the rip's log.
    var logShown = false

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
        return recentRips.first { $0.folder == url }
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
        guard slot.rip?.isRunning != true, let disc = slot.disc else { return }
        var options = DiscRipOptions(settings: settings)
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
            options.folder = URL.temporaryDirectory.appending(path: "CDRip Demo \(UUID().uuidString)")
        }
        let run = RipRun(disc: disc)
        slot.rip = run
        run.start(
            makeDrive: slot.makeDrive, identity: slot.identity, settings: settings, options: options,
            encodes: settings.encodeAfterRip && !slot.isDemo
        ) { [weak self] in
            guard let self else { return }
            refreshRecentRips()
            if settings.ejectAfterRip, run.result?.report.isVerified == true, !slot.isDemo { eject(slot) }
        }
    }

    func stopRip(_ slot: DriveSlot) {
        slot.rip?.stop()
    }

    // MARK: Earlier rips

    func refreshRecentRips() {
        let folder = settings.ripsURL
        Task.detached(priority: .utility) {
            let rips = RecentRip.scan(folder)
            await MainActor.run { self.recentRips = rips }
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealFolder(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
