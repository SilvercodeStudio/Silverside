import AppKit
import Foundation
import Observation
import SilversideDarwin
import SilversideKit

/// What the sidebar can select: a drive, or an earlier rip.
enum SidebarItem: Hashable {
    case drive(String)
    /// An earlier rip, by its key in the history (`RecentRip.id`). `AppModel.showRip(at:)`
    /// finds the rip whose report is at a file.
    case rip(String)
    /// Every earlier rip, in a table.
    case history
    /// Every multi-disc set, in a table.
    case sets
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
    /// A drive whose rip waits for the user to agree to rip only discs they own.
    var agreementSlot: DriveSlot?
    private(set) var recentRips: [RecentRip] = [] {
        didSet { listsChanged() }
    }
    /// Rips that only the history has: their files were moved or deleted.
    private(set) var missingRips: [RecentRip] = [] {
        didSet { listsChanged() }
    }
    /// Rips whose place cannot be reached now (`RecentRip.isOffline`): a library on a NAS that is
    /// not mounted. A scan when a volume is mounted finds them again.
    private(set) var offlineRips: [RecentRip] = [] {
        didSet { listsChanged() }
    }
    /// Every rip in the history, there or not, the newest first. Kept, not worked out at each
    /// use: the history's table and the sidebar read it for every change.
    private(set) var allRips: [RecentRip] = []
    /// The multi-disc releases among the earlier rips, with the discs ripped so far, the one
    /// with the newest rip first. Kept, as `allRips` is.
    private(set) var sets: [RipSet] = []

    /// Goes up when `allRips` or `sets` change, for a table that keeps its rows.
    private(set) var listsVersion = 0

    private func listsChanged() {
        listsVersion += 1
        allRips = (recentRips + offlineRips + missingRips).sorted { $0.report.date > $1.report.date }
        sets = RipSet.sets(
            in: recentRips.map { .init(folder: $0.folder, file: $0.file, report: $0.report, hasAudio: $0.hasAudio) },
            editsStore: ReleaseEditsStore()
        ).sorted { $0.lastRipped > $1.lastRipped }
    }

    /// A set's album names changed: the sidebar and the sets' table show the new ones.
    func setNamesChanged() { listsChanged() }

    /// The history's search and order, and the sets', kept here so that Back to the table finds
    /// them as they were.
    var historySearch = ""
    var historyOrder = [KeyPathComparator(\RecentRip.date, order: .reverse)]
    var setsSearch = ""
    var setsOrder = [KeyPathComparator(\RipSet.lastRipped, order: .reverse)]
    var historySelection: String?
    var setsSelection: String?
    /// True when Find (⌘F) asks the table on screen to put the insertion point in its search field.
    var wantsSearchField = false

    /// Find (⌘F): the search field of the sets' table when it shows, else the history's.
    func find() {
        if selection != .sets { selection = .history }
        wantsSearchField = true
    }
    let history = RipHistory()
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
    /// The rip whose release the Change Release sheet chooses.
    var changingRelease: RecentRip?
    /// Updates through Sparkle, in a build that `make dist` made. Made in `init`, so that its
    /// checks start at launch.
    @ObservationIgnored private(set) lazy var updater = AppUpdater { [weak self] install in
        self?.postponeRelaunch(install) ?? false
    }
    /// The `silverside` command in the app, linked into a folder on the PATH.
    let commandLineTool = CommandLineTool()

    /// False until the first look at the drives: a disc in a drive at launch is not ripped by itself.
    @ObservationIgnored private var hasListedDrives = false
    @ObservationIgnored private var watcher: DiskWatcher?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// The scan of the earlier rips that a volume's mount or unmount asks for, a moment later.
    @ObservationIgnored private var volumeScan: Task<Void, Never>?

    init() {
        settings = (try? Settings.load()) ?? Settings()
        // A table's dragged widths last while it shows; a quit leaves them saved.
        TrackColumns.forgetWidths()
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
        _ = updater
        if selection == nil { selection = drives.first.map { .drive($0.id) } }
        watcher = DiskWatcher { [weak self] in self?.discsChanged() }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDrives() }
            })
        // A NAS mounted after launch, or a disk unplugged, changes which rips are there.
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(
                NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] notification in
                    let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                    MainActor.assumeIsolated { self?.volumeChanged(volume) }
                })
        }
    }

    /// Scans the earlier rips again when a volume that holds the rips folder, the library, or
    /// any rip in the history comes or goes: a disk with albums found elsewhere can be unplugged.
    /// Several shares of a NAS mount together, and SMB can connect again just after, so the scan
    /// waits a moment for the last of them.
    private func volumeChanged(_ volume: URL?) {
        if let volume {
            let root = volume.standardizedFileURL.path
            let places =
                [settings.ripsURL, settings.libraryURL].map(\.standardizedFileURL.path)
                + (recentRips + offlineRips + missingRips).map(\.file.path)
            guard places.contains(where: { $0 == root || $0.hasPrefix(root.hasSuffix("/") ? root : root + "/") })
            else { return }
        }
        volumeScan?.cancel()
        volumeScan = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.refreshRecentRips()
        }
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
        case .rip(let id): allRips.contains { $0.id == id }
        case .history, .sets: true
        case .set(let id): sets.contains { $0.releaseID == id }
        }
    }

    var selectedRip: RecentRip? {
        guard case .rip(let id) = selection else { return nil }
        return allRips.first { $0.id == id }
    }

    /// The rip whose report is at `file` now: the one there, before an earlier rip of the disc
    /// that the history keeps at the same place.
    func rip(at file: URL) -> RecentRip? {
        recentRips.first { $0.file == file } ?? offlineRips.first { $0.file == file }
            ?? missingRips.first { $0.file == file }
    }

    /// Shows the rip whose report is at `file`.
    func showRip(at file: URL) {
        if let rip = rip(at: file) { selection = .rip(rip.id) }
    }

    /// The earlier rips of a disc that still have their audio, by its TOC: the pool for a new rip or a repair.
    func earlierRips(of tocString: String) -> [RecentRip] {
        recentRips.filter { $0.hasAudio && $0.report.toc == tocString }
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
    func startLibraryRun(
        title: String, encode: [RecentRip], update: [RecentRip], cover: CoverImage? = nil,
        discCovers: [URL: DiscCoverChange] = [:]
    ) {
        guard library?.isRunning != true else {
            libraryShown = true
            return
        }
        let run = LibraryRun(title: title, encode: encode, update: update)
        library = run
        libraryShown = true
        run.start(settings: settings, cover: cover, discCovers: discCovers) { [weak self] in
            self?.coverVersion += 1
            self?.refreshRecentRips()
        }
    }

    /// Each disc of a box set takes its own sleeve from the Cover Art Archive, from now on (a
    /// disc ripped later finds the choice kept for the release): the earlier rips and the
    /// encoded discs get theirs, and a disc that no sleeve names keeps the set's cover.
    func useDiscSleeves(of release: MusicBrainzRelease) {
        try? ReleaseCoverStore().useDiscSleeves(true, releaseID: release.id)
        let rips =
            sets.first { $0.releaseID == release.id }.map { set in
                set.positions.compactMap { set.discs[$0] }.compactMap { disc in
                    recentRips.first { $0.file == disc.file }
                }
            } ?? []
        guard !rips.isEmpty else { return }
        workCount += 1
        Task { @MainActor in
            defer { workCount -= 1 }
            do {
                let images = try await CoverArtClient().images(releaseID: release.id)
                var covers = [URL: DiscCoverChange]()
                for rip in rips {
                    let sleeve = rip.report.discPosition.flatMap { CoverArtImage.sleeve(forDisc: $0, in: images) }
                    if let sleeve, let image = try await CoverArtClient().download(sleeve) {
                        covers[rip.file] = .set(image)
                    } else {
                        covers[rip.file] = .remove
                    }
                }
                startLibraryRun(title: release.title, encode: [], update: rips, discCovers: covers)
            } catch {
                alert = AppAlert(title: "The sleeves could not be downloaded", message: "\(error)")
            }
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

    /// Decodes an earlier rip's DTS stream with ffmpeg: beside its album, its title ending in
    /// `suffix`, or in place of its files.
    func startDTSDecode(_ rip: RecentRip, beside: Bool, format: AudioFormat, suffix: String) {
        guard library?.isRunning != true else {
            libraryShown = true
            return
        }
        let run = LibraryRun(
            title: rip.title, encode: [], update: [],
            dts: LibraryRun.DTSDecode(rip: rip, beside: beside, format: format, suffix: suffix))
        library = run
        libraryShown = true
        run.start(settings: settings, cover: nil) { [weak self] in
            self?.refreshRecentRips()
        }
    }

    /// The earlier rips of a set's discs, in the order of the discs.
    func rips(of set: RipSet) -> [RecentRip] {
        set.positions.compactMap { set.discs[$0] }.compactMap { disc in recentRips.first { $0.file == disc.file } }
    }

    /// The positions of a set's discs that have covers of their own (`CoverFiles.disc`).
    func discsWithOwnCovers(_ rips: [RecentRip]) -> [Int] {
        rips.compactMap { rip in
            rip.report.discPosition.flatMap { CoverFiles.disc($0, in: rip.folder) != nil ? $0 : nil }
        }.sorted()
    }

    /// A cover for every disc of a set. Nil takes the Cover Art Archive's front cover. The
    /// discs' own covers go, unless `keepingDiscCovers`: then those discs keep embedding theirs.
    func changeCover(ofSet set: RipSet, rips: [RecentRip], to image: CoverImage?, keepingDiscCovers: Bool = false) {
        workCount += 1
        Task { @MainActor in
            defer { workCount -= 1 }
            var cover = image
            if cover == nil {
                try? ReleaseCoverStore().forget(releaseID: set.releaseID)
                // A release with no front cover of its own takes its release group's.
                if let release = rips.lazy.compactMap(\.report.release).first(where: { $0.id == set.releaseID }) {
                    cover = try? await CoverArtClient().frontCover(of: release)
                } else {
                    cover = try? await CoverArtClient().frontCover(releaseID: set.releaseID)
                }
                guard cover != nil else {
                    alert = AppAlert(
                        title: "No cover",
                        message:
                            "The Cover Art Archive has no front cover for this release, nor for the album's other releases."
                    )
                    return
                }
            }
            startLibraryRun(
                title: set.title, encode: [], update: rips, cover: cover,
                discCovers: keepingDiscCovers ? [:] : Dictionary(uniqueKeysWithValues: rips.map { ($0.file, .remove) }))
        }
    }

    /// The newest cover change of an earlier rip, which artwork saved after it waits for.
    @ObservationIgnored private var coverChange: Task<Void, Never>?

    /// Puts `images` (a release's, but its main front) in the Artwork folders of earlier rips,
    /// their rip folders and album folders, in place of the images there.
    func saveArtwork(_ images: [CoverArtImage], of rips: [RecentRip]) {
        let folders = ArtworkOffer.folders(of: rips)
        workCount += 1
        Task { @MainActor in
            defer { workCount -= 1 }
            // A cover change just asked for rewrites the same reports: it goes first.
            await coverChange?.value
            while library?.isRunning == true { try? await Task.sleep(for: .milliseconds(250)) }
            do {
                _ = try await CoverArtClient().replaceArtwork(with: images, in: folders)
                // The views show the Artwork folders' images beside the cover.
                coverVersion += 1
                refreshRecentRips()
            } catch {
                alert = AppAlert(
                    title: "The artwork could not be saved",
                    message: CoverArtPickerSheet.problem(error, with: "The images could not be downloaded")
                        + " The Artwork folders are as they were.")
            }
        }
    }

    /// Offers the artwork of the release (its own, else its release group's) for earlier
    /// rips, as Download Artwork… asks; nil when there is none but the cover.
    func artworkOffer(for release: MusicBrainzRelease, rips: [RecentRip]) async -> ArtworkOffer? {
        do {
            let found = try await CoverArtClient().artworkImages(of: release)
            guard let offer = ArtworkOffer(images: found.images, rips: rips, afterCover: false) else {
                alert = AppAlert(
                    title: "No artwork",
                    message:
                        "The Cover Art Archive has no images but the cover for this release, nor for the album's other releases."
                )
                return nil
            }
            return offer
        } catch {
            alert = AppAlert(
                title: "No artwork", message: CoverArtPickerSheet.problem(error, with: "The images could not be listed")
            )
            return nil
        }
    }

    // MARK: Drives

    /// Help › Report a Problem…: a new GitHub issue's page, filled in with the version, the Mac,
    /// and every drive with its read offset. The user sends it, or not, in the browser.
    func problemReportURL() -> URL {
        let store = try? DriveProfileStore()
        let drives = OpticalDrive.all().map { device in
            ProblemReport.Drive(
                profile: store?.profile(vendor: device.vendor, product: device.product, revision: device.revision)
                    ?? DriveProfile(vendor: device.vendor, product: device.product, revision: device.revision),
                interconnect: device.interconnect)
        }
        return ProblemReport.issueURL(drives: drives)
    }

    /// Lists the drives again. A drive that is still there keeps its state; a disc that
    /// came or went is read, or forgotten.
    func refreshDrives() {
        #if DEBUG
            // `-demoOnly` leaves the real drives alone, for work on the app with a disc in one.
            if UserDefaults.standard.bool(forKey: "demoOnly") { return }
        #endif
        let devices = OpticalDrive.all()
        // A DVD or Blu-ray disc counts too: its drive comes into view, to say what it is.
        let hasMedium = { (device: OpticalDrive) in device.discBSDName != nil || device.otherDisc != nil }
        let hadDisc = Set(drives.filter { hasMedium($0.device) }.map(\.id))
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
        let hasDisc = { (slot: DriveSlot) in slot.isDemo || hasMedium(slot.device) }
        drives = slots.enumerated()
            .sorted { hasDisc($0.element) != hasDisc($1.element) ? hasDisc($0.element) : $0.offset < $1.offset }
            .map(\.element)
        // A disc that goes in while the window shows an empty drive (or none) brings its drive
        // into view. A drive with a disc or a rip keeps the view.
        if let arrived = drives.first(where: { hasMedium($0.device) && !hadDisc.contains($0.id) }),
            selection == nil || selectedDrive.map({ !hasMedium($0.device) && $0.rip?.isRunning != true }) == true
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
        guard settings.agreedToPersonalUse else {
            slot.ripOnInsertNote = "you have not agreed to rip only discs you own"
            return
        }
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
        guard let bsdName = slot.device.discBSDName ?? slot.device.otherDiscBSDName else { return }
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
        // A name still being typed (with ⌘R, say) goes into the rip.
        slot.pendingNames.acceptAll()
        guard slot.rip?.isRunning != true, !slot.isBusy, let disc = slot.disc else { return }
        // No rip without the agreement (the welcome's, or Settings › General's); the demo disc is no disc.
        guard settings.agreedToPersonalUse || slot.isDemo else {
            agreementSlot = slot
            return
        }
        slot.stopProbe()
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
        options.keepsAccurateTracks = !slot.choices.readsEveryTrack
        let selected = slot.selectedTracks
        if selected.count != disc.toc.audioTracks.count {
            options.tracks = disc.toc.audioTracks.map(\.number).filter { selected.contains($0) }
        }
        options.releaseID = disc.release?.id
        options.edits = disc.edits.isEmpty ? nil : disc.edits
        options.manualRelease = disc.manual
        options.cdGraphics = slot.probe?.cdGraphics
        options.cdExtendedGraphics = slot.probe?.cdExtendedGraphics ?? false
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
        // The drive shows the album's new name too, as if typed there, while the disc is in it.
        run.onAlbumRenamed = { name in
            if slot.disc?.toc == disc.toc { slot.disc?.edits.album = name }
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

    // MARK: Updates

    /// Work under way that quitting would cut short, counted from when it is asked for until it
    /// ends: changes to earlier rips' covers, artwork, releases, and names (a lookup, a download,
    /// files and reports rewritten), and the scans that update the history. Each such task adds
    /// one as it is started, and takes it away when it ends, also while it waits for other work.
    @ObservationIgnored private var workCount = 0

    /// True while the app does work that quitting would cut short: a rip or its encoding, a
    /// drive's test or data track, a repair, library work, the counted work above, new names in
    /// an earlier rip's files, Check Again, a video, or the command line tool's install.
    var hasWorkUnderWay: Bool {
        drives.contains { $0.rip?.isRunning == true || $0.isBusy } || repair?.isRunning == true
            || library?.isRunning == true || workCount > 0 || !updatingNames.isEmpty || !checking.isEmpty
            || !makingVideo.isEmpty || commandLineTool.isWorking
    }

    /// An update that is ready relaunches the app at once, unless work is under way: then it
    /// waits for the work to end, and says so.
    private func postponeRelaunch(_ install: @escaping () -> Void) -> Bool {
        guard hasWorkUnderWay else { return false }
        // An alert already on show stays: the update waits all the same.
        if alert == nil {
            alert = AppAlert(
                title: "The update waits for the work to end",
                message: "Silverside installs the update and opens again when the work under way is done.")
        }
        Task { @MainActor in
            while hasWorkUnderWay { try? await Task.sleep(for: .seconds(2)) }
            install()
        }
        return true
    }

    // MARK: Repairs

    /// The folders where a rip of the disc in the slot looks for earlier copies of its tracks:
    /// the folder it would write into (a stopped rip leaves its tracks there), then the earlier
    /// rips that it pools with.
    func earlierCopyFolders(for slot: DriveSlot) -> (all: [URL], own: [URL]) {
        guard let disc = slot.disc else { return ([], []) }
        let wanted = slot.choices.folder ?? DiscRip.folder(for: disc.shownRelease, toc: disc.toc, settings: settings)
        let own = RipFolder.candidates(wanted, toc: disc.toc)
        return (own + earlierRips(of: disc.toc.ctdbTOCString).map(\.folder), own)
    }

    /// Looks for earlier copies of the slot's tracks that AccurateRip says are accurate, for
    /// the chip that says a rip keeps them. Only when a folder has track files: AccurateRip's
    /// answer is cached, so the rip itself asks no second time.
    func findEarlierCopies(for slot: DriveSlot, stamp: String) async {
        guard let disc = slot.disc, !slot.isDemo, !slot.choices.offline else {
            slot.earlierCopies = nil
            return
        }
        let (folders, own) = earlierCopyFolders(for: slot)
        if let found = slot.earlierCopies, found.folders == folders, found.stamp == stamp { return }
        let toc = disc.toc
        // The drive's offset says how much of the audio's edges a read gives (`RipPool.accurateCopy`).
        let identity = slot.identity
        let readOffset =
            (try? DriveProfileStore().profile(
                vendor: identity.vendor, product: identity.product, revision: identity.revision))?.offset?.value
        let copies = await Task.detached { () -> [Int: URL] in
            let names = toc.audioTracks.map { String(format: "Track %02d.wav", $0.number) }
            let hasTracks = folders.contains { folder in
                names.contains { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }
            }
            guard hasTracks, let records = try? await AccurateRipRecord.download(for: toc.accurateRipDiscID) else {
                return [:]
            }
            var copies = [Int: URL]()
            for track in toc.audioTracks {
                let padding = readOffset.map { DiscRip.paddedEdges(of: toc, readOffset: $0, tracks: [track.number]) }
                if let copy = RipPool.accurateCopy(
                    of: track, toc: toc, in: folders, records: records, padding: padding)
                {
                    copies[track.number] = copy.folder
                }
            }
            return copies
        }.value
        guard slot.disc?.toc == toc else { return }
        slot.earlierCopies = EarlierCopies(folders: folders, own: own, copies: copies, stamp: stamp)
    }

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
                if let folder = run.reportFolder { self?.showRip(at: folder.appending(path: "disc.json")) }
            }
        }
    }

    // MARK: Save Data Track

    /// The rips whose data track is being saved, with how far.
    private(set) var savingDataTrack: [URL: Double] = [:]

    /// A free drive with the rip's disc in it.
    func freeDrive(with rip: RecentRip) -> DriveSlot? {
        drives.first {
            !$0.isDemo && !$0.isBusy && $0.rip?.isRunning != true && $0.disc?.toc.ctdbTOCString == rip.report.toc
        }
    }

    /// The first data track of the disc that the rip did not save. Nil if it saved them all.
    func missingDataTrack(of rip: RecentRip) -> Int? {
        guard let toc = try? TOC(ctdbTOCString: rip.report.toc) else { return nil }
        let saved = Set((rip.report.dataTracks ?? []).map(\.number))
        return toc.tracks.first { $0.kind == .data && !saved.contains($0.number) }?.number
    }

    /// What Disc › Save Data Track saves: for a selected drive, the newest rip of its disc,
    /// and for a selected rip, that rip, if it lacks a data track and the disc is in a free drive.
    var dataTrackToSave: (rip: RecentRip, number: Int)? {
        let rip =
            selectedDrive.flatMap { slot in
                slot.disc.flatMap { disc in recentRips.first { $0.report.toc == disc.toc.ctdbTOCString } }
            } ?? selectedRip
        guard let rip, !rip.isMissing, savingDataTrack[rip.file] == nil, freeDrive(with: rip) != nil,
            let number = missingDataTrack(of: rip)
        else { return nil }
        return (rip, number)
    }

    /// Reads a data track that the rip did not save, from the disc in a free drive
    /// (`DiscEncoder.saveDataTrack`).
    func saveDataTrack(_ number: Int, of rip: RecentRip) {
        guard savingDataTrack[rip.file] == nil, let slot = freeDrive(with: rip) else { return }
        var encoder = DiscEncoder(settings: settings)
        // Files in the album folder that the rip did not put there are replaced only when asked.
        let conflicts = (try? encoder.dataTrackConflicts(number, reportAt: rip.file)) ?? []
        if !conflicts.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Replace the data track files in the album folder?"
            alert.informativeText =
                "The album folder has "
                + conflicts.map { "“\($0.lastPathComponent)”" }.joined(separator: " and ")
                + ", which this rip did not put there: perhaps another edition's, or files of your own. "
                + "Saving the data track replaces them."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            encoder.overwrites = true
        }
        player.stop(drive: slot.id)
        slot.isBusy = true
        slot.savingDataTrack = (number, 0)
        savingDataTrack[rip.file] = 0
        let makeDrive = slot.makeDrive
        let saver = encoder
        let file = rip.file
        Task { @MainActor in
            do {
                _ = try await Task.detached {
                    try saver.saveDataTrack(number, reportAt: file, drive: try makeDrive()) { fraction in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self.savingDataTrack[file] = fraction
                                slot.savingDataTrack = (number, fraction)
                            }
                        }
                    }
                }.value
            } catch {
                alert = AppAlert(title: "The data track could not be saved", message: "\(error)")
            }
            savingDataTrack[file] = nil
            slot.savingDataTrack = nil
            slot.isBusy = false
            refreshRecentRips()
        }
    }

    // MARK: Make Video

    /// The rips whose video of the CD+G graphics is being made, with how far.
    private(set) var makingVideo: [URL: Double] = [:]

    /// True if the rip has CD+G graphics and audio to make a video from: its WAV files, or the
    /// album's lossless files with the graphics beside them.
    func canMakeVideo(of rip: RecentRip) -> Bool {
        guard !rip.isMissing, rip.report.tracks.contains(where: { $0.graphics != nil }) else { return false }
        if rip.hasAudio { return true }
        guard let encoding = rip.report.encoding else { return false }
        return encoding.format.isLossless && encoding.graphicsFiles != nil && encoding.hdcdDecoded != true
            && encoding.dtsDecoded == nil && encoding.deEmphasizedTracks == nil
    }

    /// Makes the video of a rip's CD+G graphics (`CDGraphicsVideo`): into its album folder
    /// when it was encoded, else into the rip's folder. Finder shows it when it is done.
    func makeVideo(of rip: RecentRip, audio: CDGraphicsVideo.Audio, picture: CDGraphicsVideo.Picture = .extended) {
        guard makingVideo[rip.file] == nil, canMakeVideo(of: rip) else { return }
        makingVideo[rip.file] = 0
        let (file, folder, hasAudio) = (rip.file, rip.folder, rip.hasAudio)
        Task { @MainActor in
            do {
                let url = try await Task.detached {
                    let disc = hasAudio ? try RippedDisc(folder: folder) : try RippedDisc(albumReportAt: file)
                    var video = CDGraphicsVideo()
                    video.audio = audio
                    video.picture = picture
                    return try video.write(disc) { fraction in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                if self.makingVideo[file] != nil { self.makingVideo[file] = fraction }
                            }
                        }
                    }
                }.value
                revealInFinder(url)
            } catch {
                alert = AppAlert(title: "The video could not be made", message: "\(error)")
            }
            makingVideo[file] = nil
            refreshRecentRips()
        }
    }

    // MARK: Check Again

    /// The rips that Check Again is looking up, and the outcome of the latest check of each.
    private(set) var checking: Set<URL> = []
    private(set) var checkResults: [URL: String] = [:]
    @ObservationIgnored private var checks: Task<Void, Never>?

    /// Looks earlier rips up in AccurateRip and CTDB again (`RipCheck`), one after another,
    /// and updates their reports.
    func checkAgain(_ rips: [RecentRip]) {
        let rips = rips.filter { !checking.contains($0.file) }
        guard !rips.isEmpty else { return }
        checking.formUnion(rips.map(\.file))
        let previous = checks
        checks = Task { @MainActor in
            await previous?.value
            var failures = [String]()
            for rip in rips {
                do {
                    let file = rip.file
                    let result = try await Task.detached { try await RipCheck(reportAt: file).run() }.value
                    checkResults[rip.file] = result.summary
                } catch {
                    failures.append("\(rip.title): \(error)")
                }
                checking.remove(rip.file)
                refreshRecentRips()
            }
            if !failures.isEmpty {
                alert = AppAlert(title: "Check Again did not finish", message: failures.joined(separator: "\n"))
            }
        }
    }

    // MARK: Earlier rips

    /// True after the first look through the rips folder and the library.
    @ObservationIgnored private var hasScannedRips = false
    /// The newest scan: an older one that ends after it does not replace its lists.
    @ObservationIgnored private var scanNumber = 0

    /// Looks through the rips folder and the library again. The first time, the history's rips
    /// show at once, since a library on a NAS can take some seconds to list.
    func refreshRecentRips(then completion: (@MainActor () -> Void)? = nil) {
        let folder = settings.ripsURL
        let library = settings.libraryURL
        let history = history
        let isFirst = !hasScannedRips
        scanNumber += 1
        let number = scanNumber
        workCount += 1
        Task.detached(priority: .utility) {
            if isFirst {
                let rips = RecentRip.remembered(rips: folder, library: library, history: history)
                await MainActor.run {
                    guard !self.hasScannedRips else { return }
                    self.show(rips)
                }
            }
            let rips = RecentRip.scan(rips: folder, library: library, history: history)
            await MainActor.run {
                self.workCount -= 1
                self.hasScannedRips = true
                if number == self.scanNumber { self.show(rips) }
                completion?()
            }
        }
    }

    private func show(_ rips: RecentRip.Found) {
        recentRips = rips.present
        offlineRips = rips.offline
        missingRips = rips.missing
    }

    /// Looks for moved rips in a folder the user chooses, such as a NAS, and keeps their new places.
    func locateMissingRips() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the folder that has the moved albums or rips. Silverside looks up to six folders deep."
        panel.prompt = "Look Here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        // A replaced rip is not looked for: another rip of the disc is at its place.
        let keys = Set(missingRips.filter { !$0.isReplaced }.map(\.historyKey))
        let history = history
        workCount += 1
        Task.detached(priority: .userInitiated) {
            let found = history.locate(keys, in: folder)
            await MainActor.run {
                self.workCount -= 1
                self.refreshRecentRips()
                self.alert = AppAlert(
                    title: found == 0 ? "No moved rips found there" : "Found \(Format.count(found, "rip"))",
                    message: found == 0
                        ? "None of the missing rips' reports is in \(folder.path)."
                        : "The history now has their new places. \(keys.count - found) still missing.")
            }
        }
    }

    /// Takes a missing rip out of the history.
    func forget(_ rip: RecentRip) {
        try? history.forget(key: rip.historyKey)
        if selection == .rip(rip.id) { selection = .history }
        refreshRecentRips()
    }

    /// Encodes a rip that is not verified, after the user accepts it as it is
    /// (`RipReport.accept`). The report keeps the acceptance; the rip then goes as a verified
    /// one does, unless Settings keep it. Returns false if the user cancels, or the rip cannot
    /// be accepted.
    @discardableResult func acceptAndEncode(_ rip: RecentRip) -> Bool {
        let unverified = rip.report.unverifiedTracks
        let tracks = "\(unverified.count == 1 ? "Track" : "Tracks") \(RipSet.list(unverified))"
        let alert = NSAlert()
        alert.messageText = "Accept this rip as-is, and encode it?"
        alert.informativeText =
            "\(tracks) \(unverified.count == 1 ? "is" : "are") not verified: AccurateRip and CTDB do not prove "
            + (unverified.count == 1 ? "it" : "them") + ", so there can be errors. Listen to "
            + (unverified.count == 1 ? "it" : "them") + " first. The rip is encoded into the library as a "
            + "verified rip is, and its report says that you accepted it."
            + (settings.keepRipAfterEncoding
                ? "" : " Then the rip's WAV files are deleted, so it can no longer be repaired.")
        alert.addButton(withTitle: "Accept and Encode")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            try RipReport.accept(reportAt: rip.file)
        } catch {
            self.alert = AppAlert(title: "The rip could not be accepted", message: "\(error)")
            return false
        }
        refreshRecentRips()
        startLibraryRun(title: rip.title, encode: [rip], update: [])
        return true
    }

    /// True while nothing else works on the rip's files: no repair, no name update, and no rip,
    /// which can write into an earlier rip's folder or album folder. A rip from the command line
    /// is kept out by the folder's claim (`RipRemoval.moveToTrash`).
    func canMoveToTrash(_ rip: RecentRip) -> Bool {
        !rip.isMissing && !updatingNames.contains(rip.file) && repair?.isRunning != true
            && !drives.contains { $0.rip?.isRunning == true }
    }

    /// Moves an earlier rip's own files to the Trash (`RipRemoval`), after asking, and takes
    /// the rip out of the history.
    func moveToTrash(_ rip: RecentRip) {
        let files = RipRemoval.files(ofReportAt: rip.file, hasAudio: rip.hasAudio)
        let encoded = files.filter { !["json", "md"].contains($0.pathExtension) }.count
        let alert = NSAlert()
        alert.messageText = "Move “\(rip.title)” to the Trash?"
        alert.informativeText =
            rip.hasAudio
            ? "The rip's folder, with its WAV files, goes to the Trash. Files encoded into the library stay."
            : "The rip's report" + (encoded > 0 ? " and \(Format.count(encoded, "other file"))" : "")
                + " go to the Trash: its encoded files, CUE sheet, and disc image. Files that another rip in the "
                + "album folder uses, and the cover, stay."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, canMoveToTrash(rip) else { return }
        do {
            try RipRemoval.moveToTrash(reportAt: rip.file, hasAudio: rip.hasAudio)
            forget(rip)
        } catch {
            // The report goes last, so a rip that is only partly in the Trash keeps it, and its
            // place in the history, to try again.
            self.alert = AppAlert(title: "The rip could not be moved to the Trash", message: "\(error)")
            refreshRecentRips()
        }
    }

    /// Changes an earlier rip's cover: the cover file in the rip's folder and the album's, the
    /// tags of the encoded files, and the cover kept for the release. Nil puts the Cover Art
    /// Archive's front cover back.
    func changeCover(of rip: RecentRip, to image: CoverImage?) {
        let settings = settings
        workCount += 1
        coverChange = Task { @MainActor in
            defer { workCount -= 1 }
            do {
                var cover = image
                if cover == nil, let release = rip.report.release, !release.isManual {
                    try? ReleaseCoverStore().forget(releaseID: release.id)
                    cover = try await CoverArtClient().frontCover(of: release)
                }
                guard let cover else {
                    alert = AppAlert(
                        title: "No cover",
                        message:
                            "The Cover Art Archive has no front cover for this release, nor for the album's other releases."
                    )
                    return
                }
                let (file, remember) = (rip.file, image != nil)
                _ = try await Task.detached {
                    try DiscEncoder(settings: settings).retag(
                        reportAt: file, cover: cover, remember: remember, discCover: .remove,
                        library: settings.libraryURL)
                }.value
                coverVersion += 1
                refreshRecentRips()
            } catch {
                alert = AppAlert(title: "The cover could not be changed", message: "\(error)")
            }
        }
    }

    /// Gives one disc of a set a cover of its own, which its files embed in place of the set's
    /// (each volume of a box, say: *Anthology* 1 for discs 1 and 2); nil takes it away, so the
    /// disc embeds the set's cover again. The set's cover and the other discs stay as they are.
    func changeDiscCover(of rip: RecentRip, to image: CoverImage?) {
        let settings = settings
        workCount += 1
        coverChange = Task { @MainActor in
            defer { workCount -= 1 }
            do {
                let (file, change): (URL, DiscCoverChange) = (rip.file, image.map { .set($0) } ?? .remove)
                _ = try await Task.detached {
                    try DiscEncoder(settings: settings).retag(
                        reportAt: file, remember: false, discCover: change, library: settings.libraryURL)
                }.value
                coverVersion += 1
                refreshRecentRips()
            } catch {
                alert = AppAlert(title: "The disc's cover could not be changed", message: "\(error)")
            }
        }
    }

    /// True while nothing else works on the rip's files, as for Move to Trash, and no other
    /// library work runs.
    func canChangeRelease(_ rip: RecentRip) -> Bool {
        rip.report.release != nil && canMoveToTrash(rip) && library?.isRunning != true
    }

    /// Change Release: gives an earlier rip another release that has its disc, and brings its
    /// files up to date (`DiscEncoder.changeRelease`), with the release's cover if the Cover Art
    /// Archive has one. The other encoded discs of the old and the new release are brought up to
    /// date after it, for their album gain. The selection follows a report that moved.
    func changeRelease(of rip: RecentRip, to chosen: MusicBrainzRelease, keepingTitles: Bool = false) {
        guard canChangeRelease(rip) else { return }
        // A disc of a custom set that moves to a release of MusicBrainz's leaves the set, once
        // the change is made, so that it is not named as the set's when it goes in a drive again.
        let leavesSet =
            rip.report.release?.isCustomSet == true && !chosen.isCustomSet
            ? try? TOC(ctdbTOCString: rip.report.toc) : nil
        let old = rip.report.release?.id
        let others = recentRips.filter { other in
            other.file != rip.file && (other.report.encoding != nil || !other.hasAudio)
                && [old, chosen.id].contains(other.report.release?.id)
        }
        workCount += 1
        Task { @MainActor in
            defer { workCount -= 1 }
            // The picker's releases are the disc lookup's; the details (writers, genre) come by ID.
            let release = ((try? await MusicBrainzClient().release(id: chosen.id)) ?? nil) ?? chosen
            var cover = ReleaseCoverStore().cover(forReleaseID: release.id)
            if cover == nil {
                cover = try? await CoverArtClient().frontCover(
                    of: release, from: ReleaseCoverStore().artworkRelease(forReleaseID: release.id))
            }
            let run = LibraryRun(
                title: rip.title, encode: [], update: others,
                change: .init(rip: rip, release: release, cover: cover, keepsTrackTitles: keepingTitles))
            library = run
            libraryShown = true
            run.start(settings: settings, cover: nil) { [self] in
                if run.changedReport != nil, let leavesSet { try? CustomSetStore().remove(leavesSet) }
                coverVersion += 1
                refreshRecentRips()
            }
        }
    }

    /// Puts an earlier rip of a disc that MusicBrainz does not know in a custom set, at `position`,
    /// and brings its files up to date, as Change Release does; the rip keeps its names for its
    /// tracks, and the album's are the set's. A disc that was at `position` leaves the set first,
    /// as Take Out of Set does. The set's other encoded discs follow, for their gain.
    func putInCustomSet(_ rip: RecentRip, set: CustomSet, at position: Int) {
        guard canChangeRelease(rip), let own = rip.report.release, let toc = try? TOC(ctdbTOCString: rip.report.toc)
        else { return }
        let displaced = ripsDisplaced(in: set, at: position, by: toc)
        guard displaced.allSatisfy(canMoveToTrash) else {
            alert = AppAlert(
                title: "Disc \(position) cannot change now",
                message:
                    "Its earlier rip must leave the set, and other work is using its files. Try again when it ends.")
            return
        }
        var set = set
        set.put(toc, at: position, namedAs: own)
        let release = set.release
        let others = recentRips.filter { other in
            other.file != rip.file && !displaced.contains { $0.file == other.file }
                && (other.report.encoding != nil || !other.hasAudio)
                && [own.id, release.id].contains(other.report.release?.id)
        }
        let run = LibraryRun(
            title: rip.title, encode: [], update: others,
            change: .init(
                rip: rip, release: release, cover: ReleaseCoverStore().cover(forReleaseID: release.id),
                keepsTrackNames: true),
            leaving: displaced)
        library = run
        libraryShown = true
        run.start(settings: settings, cover: nil) { [self] in
            // The set changes only once the rip's files have, and every rip of the disc that was
            // there has left: else two rips would be that disc. A disc that left its place for
            // this one is out of the set either way.
            if run.changedReport != nil, displaced.allSatisfy({ run.leftRips.contains($0.file) }) {
                do {
                    try CustomSetStore().save(set)
                } catch {
                    alert = AppAlert(title: "The set could not be saved", message: "\(error)")
                }
            } else {
                for gone in displaced where run.leftRips.contains(gone.file) {
                    if let toc = try? TOC(ctdbTOCString: gone.report.toc) { try? CustomSetStore().remove(toc) }
                }
                if !displaced.allSatisfy({ run.leftRips.contains($0.file) }) {
                    alert = AppAlert(
                        title: "The rip was not put in the set",
                        message: "The earlier rip of disc \(position) could not leave the set. The log says why.")
                }
            }
            coverVersion += 1
            refreshRecentRips()
        }
    }

    /// The earlier rips of the disc that `set` has at `position`, when the disc with `toc` takes
    /// its place there: they leave the set, or two rips would be the same disc of one album.
    private func ripsDisplaced(in set: CustomSet, at position: Int, by toc: TOC) -> [RecentRip] {
        guard let there = set.disc(at: position), there.discID != toc.musicBrainzDiscID else { return [] }
        return recentRips.filter { rip in
            !rip.isMissing && rip.report.release?.id == set.id
                && (try? TOC(ctdbTOCString: rip.report.toc))?.musicBrainzDiscID == there.discID
        }
    }

    /// What a sheet about a disc is for: the disc in a drive, or an earlier rip.
    enum DiscTarget: Identifiable {
        case drive(DriveSlot)
        case rip(RecentRip)

        var id: String {
            switch self {
            case .drive(let slot): "drive " + slot.id
            case .rip(let rip): "rip " + rip.file.path
            }
        }
    }

    /// The disc or rip the custom set sheet shows, if it shows.
    var customSetTarget: DiscTarget?

    /// The rip whose notes the notes sheet edits, if it shows.
    var notesRip: RecentRip?

    /// Saves the user's notes on an earlier rip (`RipReport.saveNotes`).
    func saveNotes(_ notes: String, of rip: RecentRip) {
        do {
            try RipReport.saveNotes(notes, of: rip.report, at: rip.file, hasAudio: rip.hasAudio, history: history)
        } catch {
            alert = AppAlert(title: "The notes could not be saved", message: "\(error)")
        }
        refreshRecentRips()
    }

    /// The disc or rip the MusicBrainz search shows, if it shows.
    var releaseSearchTarget: DiscTarget?

    /// What Disc › Put in Custom Set… and Search MusicBrainz… would show the sheet for: the selected drive's disc, before
    /// or after a rip but not during one, or the selected earlier rip, while nothing works on its files.
    var discCandidate: DiscTarget? {
        if let slot = selectedDrive, let disc = slot.disc, !disc.toc.audioTracks.isEmpty, disc.lookup != .lookingUp,
            slot.rip?.isRunning != true
        {
            return .drive(slot)
        }
        if let rip = selectedRip, !rip.isMissing, canChangeRelease(rip) { return .rip(rip) }
        return nil
    }

    /// True if the candidate is in a custom set already, for the menu's title.
    var discCandidateIsInSet: Bool {
        switch discCandidate {
        case .drive(let slot): slot.disc?.customSet != nil
        case .rip(let rip): rip.report.release?.isCustomSet == true
        case nil: false
        }
    }

    /// Takes the disc in a drive out of its custom set.
    func takeOutOfCustomSet(_ slot: DriveSlot) {
        slot.changeDisc { await $0.leaveCustomSet() }
    }

    /// Puts the disc in a drive in a custom set, at `position`, before its rip. The earlier rips of
    /// a disc that was at `position` leave the set, as Take Out of Set does, and the set's other
    /// encoded discs follow, for their gain.
    func putInCustomSet(_ slot: DriveSlot, set: CustomSet, at position: Int) {
        guard let disc = slot.disc else { return }
        let displaced = ripsDisplaced(in: set, at: position, by: disc.toc)
        if !displaced.isEmpty, library?.isRunning == true || displaced.contains(where: { !canMoveToTrash($0) }) {
            alert = AppAlert(
                title: "Disc \(position) cannot change now",
                message:
                    "Its earlier rip must leave the set, and other work is using its files. Try again when it ends.")
            return
        }
        var set = set
        set.put(disc.toc, at: position, tracks: disc.tracksForSet)
        let toc = disc.toc
        func commit() {
            do {
                try CustomSetStore().save(set)
            } catch {
                alert = AppAlert(title: "The set could not be saved", message: "\(error)")
                return
            }
            if slot.disc?.toc.musicBrainzDiscID == toc.musicBrainzDiscID { slot.disc?.useCustomSet(set) }
        }
        guard !displaced.isEmpty else { return commit() }
        // The set changes only once the rips of the disc there have left it: else two rips
        // would be that disc of the set.
        let others = recentRips.filter { other in
            !displaced.contains { $0.file == other.file } && (other.report.encoding != nil || !other.hasAudio)
                && other.report.release?.id == set.id
        }
        let run = LibraryRun(title: set.title, encode: [], update: others, leaving: displaced)
        library = run
        libraryShown = true
        run.start(settings: settings, cover: nil) { [self] in
            if displaced.allSatisfy({ run.leftRips.contains($0.file) }) {
                commit()
            } else {
                // A rip that left is out of the set either way; the disc in the drive is not in it.
                for gone in displaced where run.leftRips.contains(gone.file) {
                    if let toc = try? TOC(ctdbTOCString: gone.report.toc) { try? CustomSetStore().remove(toc) }
                }
                alert = AppAlert(
                    title: "The disc was not put in the set",
                    message: "The earlier rip of disc \(position) could not leave the set. The log says why.")
            }
            refreshRecentRips()
        }
    }

    /// Takes an earlier rip out of its custom set: it becomes a disc of its own again, with the
    /// names the set had for it as its own edits (`DiscEncoder.leaveCustomSet`). The set's other
    /// encoded discs follow, for their album gain.
    func takeOutOfCustomSet(_ rip: RecentRip) {
        guard canChangeRelease(rip), let own = rip.report.release, own.isCustomSet,
            let toc = try? TOC(ctdbTOCString: rip.report.toc)
        else { return }
        let others = recentRips.filter { other in
            other.file != rip.file && (other.report.encoding != nil || !other.hasAudio)
                && other.report.release?.id == own.id
        }
        let run = LibraryRun(
            title: rip.title, encode: [], update: others,
            change: .init(rip: rip, release: own, cover: nil, leavesCustomSet: true))
        library = run
        libraryShown = true
        run.start(settings: settings, cover: nil) { [self] in
            // The set changes only once the rip's files have.
            if run.changedReport != nil { try? CustomSetStore().remove(toc) }
            refreshRecentRips()
        }
    }

    /// No Release for an earlier rip whose release only nearly fit its disc: the rip becomes a
    /// disc of its own, with the names it has now (`DiscEncoder.useNoRelease`). The release's
    /// other encoded rips follow, for their album gain, and the disc in a drive, if it is in one.
    func useNoRelease(for rip: RecentRip) {
        guard canChangeRelease(rip), let old = rip.report.release, !old.isManual else { return }
        let others = recentRips.filter { other in
            other.file != rip.file && (other.report.encoding != nil || !other.hasAudio)
                && other.report.release?.id == old.id
        }
        let run = LibraryRun(
            title: rip.title, encode: [], update: others,
            change: .init(rip: rip, release: old, cover: nil, dropsRelease: true))
        library = run
        libraryShown = true
        run.start(settings: settings, cover: nil) { [self] in
            if run.changedReport != nil {
                for slot in drives
                where slot.disc?.toc.ctdbTOCString == rip.report.toc && slot.disc?.release?.id == old.id
                    && slot.rip?.isRunning != true
                {
                    slot.useNoRelease()
                }
            }
            coverVersion += 1
            refreshRecentRips()
        }
    }

    /// Look Up Metadata for an earlier rip: its release as MusicBrainz has it now (a disc ID
    /// added there since the rip, or names changed), into the reports of every rip of the
    /// release, so a set's discs all follow. The encoded files are brought up to date when names
    /// changed; a disc ID alone changes no file.
    func lookUpAgain(_ rip: RecentRip) {
        guard let release = rip.report.release, !release.isManual, library?.isRunning != true,
            !lookingUpReleases.contains(release.id)
        else { return }
        lookingUpReleases.insert(release.id)
        workCount += 1
        Task { @MainActor in
            defer { workCount -= 1 }
            defer { lookingUpReleases.remove(release.id) }
            let fresh: MusicBrainzRelease?
            do {
                fresh = try await MusicBrainzClient().release(id: release.id, useCache: false)
            } catch {
                alert = AppAlert(title: "MusicBrainz did not answer", message: "\(error)")
                return
            }
            guard let fresh else {
                alert = AppAlert(
                    title: "MusicBrainz no longer has this release",
                    message: "It may have been merged into another. Use Change Release… to choose it.")
                return
            }
            let rips = recentRips.filter { $0.report.release?.id == release.id && canChangeRelease($0) }
            var renamed = [RecentRip]()
            for other in rips {
                do {
                    try DiscEncoder(settings: settings).refreshRelease(
                        reportAt: other.file, with: fresh, library: settings.libraryURL)
                } catch {
                    alert = AppAlert(title: "\(other.title) could not be updated", message: "\(error)")
                    continue
                }
                // Disc IDs change no name; other changes go into the files.
                func names(_ release: MusicBrainzRelease?) -> MusicBrainzRelease? {
                    guard var release else { return nil }
                    for index in release.media.indices { release.media[index].discIDs = [] }
                    return release
                }
                // A rip encoded from the terminal has its album's record only now (`refreshRelease`).
                let encoded = (try? RipReport.read(from: other.file))?.encoding != nil
                if names(other.report.release) != names(fresh), encoded || !other.hasAudio {
                    renamed.append(other)
                }
            }
            if renamed.isEmpty {
                refreshRecentRips()
            } else {
                startLibraryRun(title: fresh.title, encode: [], update: renamed)
            }
        }
    }

    /// The releases that Look Up Metadata asks MusicBrainz for now: one request at a time for each.
    private(set) var lookingUpReleases: Set<String> = []

    /// Library updates for changed names, one after another, so two never touch one album at once.
    @ObservationIgnored private var namesUpdate: Task<Void, Never>?
    /// The rips whose files are being brought up to date with their names.
    private(set) var updatingNames: Set<URL> = []
    /// The rips whose album names are being written: the album folder, with the report, can
    /// move, so no other name can be saved to the report's place until it is done.
    private(set) var renamingAlbums: Set<URL> = []
    /// The newest edits of each rip whose update waits for the one before it.
    @ObservationIgnored private var waitingEdits: [URL: MetadataEdits] = [:]

    /// Saves an earlier rip's own edits (its track titles and artists) in its report, then
    /// writes the names into its encoded files and renames them, as Update the Library does.
    /// The selection follows a report that moved with its album folder. Names saved while an
    /// update waits go into that update, so Tab through ten titles writes the files once or twice.
    func saveNames(_ edits: MetadataEdits, of rip: RecentRip, renamesAlbum: Bool) {
        if renamesAlbum { renamingAlbums.insert(rip.file) }
        updatingNames.insert(rip.file)
        guard waitingEdits.updateValue(edits, forKey: rip.file) == nil else { return }
        let settings = settings
        let previous = namesUpdate
        namesUpdate = Task { @MainActor in
            // The update before this one writes the report too, so the save waits for it.
            await previous?.value
            guard let edits = waitingEdits.removeValue(forKey: rip.file) else { return }
            do {
                try edits.save(inReportAt: rip.file)
                // A renamed album moves its report; the rip keeps its key, so the selection follows.
                _ = try await Task.detached {
                    try DiscEncoder(settings: settings).updateLibrary(reportAt: rip.file, library: settings.libraryURL)
                }.value
            } catch {
                alert = AppAlert(title: "The library could not be updated", message: "\(error)")
            }
            if waitingEdits[rip.file] == nil {
                updatingNames.remove(rip.file)
                renamingAlbums.remove(rip.file)
            }
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
