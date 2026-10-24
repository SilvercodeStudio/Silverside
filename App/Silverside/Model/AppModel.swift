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
    /// A multi-disc release among the earlier rips, by its MusicBrainz ID.
    case set(String)
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
    var selection: SidebarItem? {
        didSet {
            guard selection != oldValue, let oldValue, !isMovingInHistory else { return }
            backItems.append(oldValue)
            if backItems.count > Self.historyLimit { backItems.removeFirst() }
            forwardItems.removeAll()
        }
    }
    /// The places shown before the selection, the newest last, as a browser keeps them.
    private(set) var backItems: [SidebarItem] = []
    /// The places that Back left, the nearest last.
    private(set) var forwardItems: [SidebarItem] = []
    @ObservationIgnored private var isMovingInHistory = false
    private static let historyLimit = 50
    var alert: AppAlert?
    /// True while a sheet or panel shows the rip's log.
    var logShown = false
    /// The repair under way, or the last one, shown in a sheet.
    private(set) var repair: RepairRun?
    var repairShown = false
    /// Plays a track of a disc or of an earlier rip, one at a time.
    let player = Player()
    /// Goes up when an earlier rip's cover changes, so its view loads the cover again.
    private(set) var coverVersion = 0
    /// Work on the library under way, or the last, shown in a sheet.
    private(set) var library: LibraryRun?
    var libraryShown = false

    /// False until the first look at the drives: a disc in a drive at launch is not ripped by itself.
    @ObservationIgnored private var hasListedDrives = false
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

    var canGoBack: Bool { backItems.contains(where: exists) }
    var canGoForward: Bool { forwardItems.contains(where: exists) }

    /// Shows the place before this one, as the toolbar's back arrow does. A drive, rip, or set
    /// that is gone since is skipped.
    func goBack() {
        move(from: &backItems, to: &forwardItems)
    }

    func goForward() {
        move(from: &forwardItems, to: &backItems)
    }

    private func move(from source: inout [SidebarItem], to target: inout [SidebarItem]) {
        while let item = source.popLast() {
            guard exists(item) else { continue }
            if let selection { target.append(selection) }
            isMovingInHistory = true
            selection = item
            isMovingInHistory = false
            return
        }
    }

    private func exists(_ item: SidebarItem) -> Bool {
        switch item {
        case .drive(let id): drives.contains { $0.id == id }
        case .rip(let url): recentRips.contains { $0.file == url }
        case .history: true
        case .set(let id): sets.contains { $0.releaseID == id }
        }
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
    var sets: [RipSet] {
        RipSet.sets(
            in: recentRips.map { .init(folder: $0.folder, file: $0.file, report: $0.report, hasAudio: $0.hasAudio) })
    }

    func set(for release: MusicBrainzRelease?) -> RipSet? {
        guard let release, release.media.count > 1 else { return nil }
        return sets.first { $0.releaseID == release.id }
    }

    /// The set that the sidebar selects, if any.
    var selectedSet: RipSet? {
        guard case .set(let id) = selection else { return nil }
        return sets.first { $0.releaseID == id }
    }

    /// Encodes rips into the library, and brings encoded ones up to date, in a sheet.
    func startLibraryRun(title: String, encode: [RecentRip], update: [RecentRip], cover: CoverImage? = nil) {
        guard library?.isRunning != true else {
            libraryShown = true
            return
        }
        let run = LibraryRun(title: title, encode: encode, update: update)
        library = run
        libraryShown = true
        run.start(settings: settings, cover: cover) { [weak self] in
            self?.coverVersion += 1
            self?.refreshRecentRips()
        }
    }

    /// Decodes an earlier rip's HDCD codes: beside its album, its title ending in `suffix`, or
    /// in place of its files.
    func startHDCDDecode(_ rip: RecentRip, beside: Bool, format: AudioFormat, suffix: String) {
        guard library?.isRunning != true else {
            libraryShown = true
            return
        }
        let run = LibraryRun(
            title: rip.title, encode: [], update: [],
            hdcd: LibraryRun.HDCDDecode(rip: rip, beside: beside, format: format, suffix: suffix))
        library = run
        libraryShown = true
        run.start(settings: settings, cover: nil) { [weak self] in
            self?.refreshRecentRips()
        }
    }

    /// A cover for every disc of a set. Nil takes the Cover Art Archive's front cover.
    func changeCover(ofSet set: RipSet, rips: [RecentRip], to image: CoverImage?) {
        Task { @MainActor in
            var cover = image
            if cover == nil {
                try? ReleaseCoverStore().forget(releaseID: set.releaseID)
                cover = try? await CoverArtClient().frontCover(releaseID: set.releaseID)
                guard cover != nil else {
                    alert = AppAlert(
                        title: "No cover", message: "The Cover Art Archive has no front cover for this release.")
                    return
                }
            }
            startLibraryRun(title: set.title, encode: [], update: rips, cover: cover)
        }
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
        let hadDisc = Set(drives.filter { $0.device.discBSDName != nil }.map(\.id))
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
        // Drives with a disc first, then the empty ones, each in the registry's order.
        let hasDisc = { (slot: DriveSlot) in slot.isDemo || slot.device.discBSDName != nil }
        drives = slots.enumerated()
            .sorted { hasDisc($0.element) != hasDisc($1.element) ? hasDisc($0.element) : $0.offset < $1.offset }
            .map(\.element)
        // A disc that goes in while the window shows an empty drive (or none) brings its drive
        // into view. A drive with a disc or a rip keeps the view.
        if let arrived = drives.first(where: { $0.device.discBSDName != nil && !hadDisc.contains($0.id) }),
            selection == nil || selectedDrive.map({ $0.device.discBSDName == nil && $0.rip?.isRunning != true }) == true
        {
            selection = .drive(arrived.id)
        }
        let inserted = hasListedDrives
        hasListedDrives = true
        for slot in drives where slot.needsDisc {
            slot.readDisc(settings: settings) { [weak self] in
                if inserted { self?.considerRipOnInsert(slot) }
            }
        }
        for slot in drives where !slot.isDemo && slot.device.discBSDName == nil { player.stop(drive: slot.id) }
    }

    /// Seconds between a disc's lookup and its rip, with "rip it at once" on.
    static let ripOnInsertDelay: TimeInterval = 5

    /// With "rip it at once" on, a disc that just went in rips after a few seconds, if its
    /// release is certain and it is not ripped yet. Otherwise the slot says why it waits.
    func considerRipOnInsert(_ slot: DriveSlot) {
        guard settings.ripOnInsert, !slot.isDemo, slot.rip == nil, !slot.isBusy, let disc = slot.disc else { return }
        if let reason = Self.reasonNotToRipOnInsert(disc, earlierRips: recentRips) {
            slot.ripOnInsertNote = reason
            return
        }
        let date = Date().addingTimeInterval(Self.ripOnInsertDelay)
        slot.ripOnInsertDate = date
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.ripOnInsertDelay))
            // Cancelled, started by hand, or another disc since: the date is not this one.
            guard let self, slot.ripOnInsertDate == date else { return }
            slot.ripOnInsertDate = nil
            startRip(slot)
        }
    }

    /// Why a disc should wait for the user, or nil to rip it.
    static func reasonNotToRipOnInsert(_ disc: DiscInfo, earlierRips: [RecentRip]) -> String? {
        switch disc.lookup {
        case .found: break
        case .notFound: return "MusicBrainz does not know this disc"
        case .failed: return "the MusicBrainz lookup failed"
        case .notLookedUp, .lookingUp: return "the disc is not looked up yet"
        }
        guard let release = disc.release else { return "MusicBrainz does not know this disc" }
        if disc.isAmbiguous { return "several releases have this disc" }
        if disc.isFuzzy && !ReleaseChoiceStore().allChoices().contains(release.id) {
            return "MusicBrainz matched the disc by its track lengths only"
        }
        if earlierRips.contains(where: { $0.report.toc == disc.toc.ctdbTOCString }) {
            return "this disc is ripped already"
        }
        return nil
    }

    /// Starts a rip that waits for its few seconds now.
    func ripNow(_ slot: DriveSlot) {
        slot.ripOnInsertDate = nil
        startRip(slot)
    }

    func cancelRipOnInsert(_ slot: DriveSlot) {
        slot.ripOnInsertDate = nil
        slot.ripOnInsertNote = nil
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
        player.stop(drive: slot.id)
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
        slot.ripOnInsertDate = nil
        slot.ripOnInsertNote = nil
        player.stop(drive: slot.id)
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
            options.addsToMusic = false
            options.readOffset = 6
            options.folder = URL.temporaryDirectory.appending(path: "Silverside Demo \(UUID().uuidString)")
        }
        let run = RipRun(disc: disc)
        slot.rip = run
        run.onProgress = { [weak self] in self?.updateDock() }
        // The question waits for the user, so it shows the drive, and asks for attention behind other apps.
        run.onQuestion = { [weak self] in
            self?.selection = .drive(slot.id)
            if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
        }
        // A demo rip is offline, so nothing is verified, and it encodes into a library of its own.
        run.start(
            makeDrive: slot.makeDrive, identity: slot.identity, settings: settings, options: options,
            encodes: settings.encodeAfterRip, allowsUnverified: slot.isDemo,
            library: slot.isDemo ? URL.temporaryDirectory.appending(path: "Silverside Demo Library") : nil
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
        if let slot { player.stop(drive: slot.id) }
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

    /// Changes an earlier rip's cover: the cover file in the rip's folder and the album's, the
    /// tags of the encoded files, and the cover kept for the release. Nil puts the Cover Art
    /// Archive's front cover back.
    func changeCover(of rip: RecentRip, to image: CoverImage?) {
        let settings = settings
        Task { @MainActor in
            do {
                var cover = image
                if cover == nil, let release = rip.report.release, !release.isManual {
                    try? ReleaseCoverStore().forget(releaseID: release.id)
                    cover = try await CoverArtClient().frontCover(releaseID: release.id)
                }
                guard let cover else {
                    alert = AppAlert(
                        title: "No cover", message: "The Cover Art Archive has no front cover for this release.")
                    return
                }
                let (file, remember) = (rip.file, image != nil)
                _ = try await Task.detached {
                    try DiscEncoder(settings: settings).retag(
                        reportAt: file, cover: cover, remember: remember, library: settings.libraryURL)
                }.value
                coverVersion += 1
                refreshRecentRips()
            } catch {
                alert = AppAlert(title: "The cover could not be changed", message: "\(error)")
            }
        }
    }

    /// Library updates for changed names, one after another, so two never touch one album at once.
    @ObservationIgnored private var namesUpdate: Task<Void, Never>?
    /// The rips whose files are being brought up to date with their names.
    private(set) var updatingNames: Set<URL> = []

    /// Saves an earlier rip's own edits (its track titles and artists) in its report, then
    /// writes the names into its encoded files and renames them, as Update the Library does.
    /// The selection follows a report that moved with its album folder.
    func saveNames(_ edits: MetadataEdits, of rip: RecentRip) {
        let settings = settings
        let previous = namesUpdate
        updatingNames.insert(rip.file)
        namesUpdate = Task { @MainActor in
            // The update before this one writes the report too, so the save waits for it.
            await previous?.value
            do {
                try edits.save(inReportAt: rip.file)
                let update = try await Task.detached {
                    try DiscEncoder(settings: settings).updateLibrary(reportAt: rip.file, library: settings.libraryURL)
                }.value
                if !rip.hasAudio, let album = update.albumFolder, selection == .rip(rip.file) {
                    selection = .rip(album.appending(path: rip.file.lastPathComponent))
                }
            } catch {
                alert = AppAlert(title: "The library could not be updated", message: "\(error)")
            }
            updatingNames.remove(rip.file)
            refreshRecentRips()
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealFolder(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
