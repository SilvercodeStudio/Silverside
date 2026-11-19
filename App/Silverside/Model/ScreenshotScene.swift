#if DEBUG
    import AppKit
    import SilversideDarwin
    import SilversideKit

    /// Debug aid for the site's screenshots: `-scene file.json` shows the app as a scene file
    /// describes it, from the rip history, so a screenshot can be taken again after the look
    /// changes (`docs/site/tools/screenshots.sh`). The drives are named as in the file, each with
    /// the disc of an earlier rip, read from that rip's report: its TOC, MCN, CD-Text, and HDCD
    /// codes, then looked up as a disc that goes in is. The sidebar lists the history as it was
    /// at a time. A drive can show its rip under way or finished, from the report too. No drive
    /// is read, and nothing is written but the scratch settings file the scene runs with.
    ///
    /// ```json
    /// {
    ///   "historyUntil": "2026-11-01T18:21:07Z",
    ///   "window": { "width": 1200, "height": 675, "sidebar": true },
    ///   "drives": [
    ///     { "vendor": "MATSHITA", "product": "BD-MLT UJ260AF", "disc": "2026-11-01T20:32:34Z",
    ///       "selected": true, "rip": { "track": 4, "fraction": 0.63, "elapsed": 129, "speed": 12.9 } },
    ///     { "vendor": "ASUS", "product": "BW-16D1HT" }
    ///   ]
    /// }
    /// ```
    ///
    /// - `historyUntil`: the rips of the history up to this time are the earlier rips; with none,
    ///   every rip is.
    /// - `window`: the main window's size, and false `sidebar` to hide the sidebar.
    /// - `drives`: `disc` names the rip by its time, the report's `date`. A `rip` with a `track` is
    ///   under way there, `fraction` of the way through it, its clock stopped at `elapsed`
    ///   seconds; one with no `track` is finished, and `elapsed` is the time it took.
    /// - What the window shows, in place of a `selected` drive: `rip`, an earlier rip by its time;
    ///   `set`, the multi-disc set whose title starts so; or `history`, the table of every rip.
    ///   `scroll` "bottom" scrolls the table to its last row, and a number scrolls the front
    ///   window's content that many points down, as Settings' Encoding tab; `expand` true opens
    ///   every row of an outline, such as a set's discs; `tabs` presses Tab that often in the
    ///   front window, to give a button the focus, as About's Leave a Tip.
    /// - `settings`: keys of the settings file to change, for this run only.
    /// - `mainWindow`: false makes the main window invisible, so that a window that `arguments`
    ///   opens, or a sheet, has the desktop around it, as the main window has.
    ///
    /// The script reads `arguments` (more launch arguments, such as `-openWindow about`),
    /// `widths`, `radius` (of the window's corners in the screenshot), and `capture` ("window" for
    /// a screenshot of one window alone). Run with
    /// `SILVERSIDE_CACHE_ONLY=1`, so the lookups ask MusicBrainz nothing.
    struct ScreenshotScene: Decodable {
        struct Window: Decodable {
            var width: Double
            var height: Double
            /// False hides the sidebar.
            var sidebar: Bool?
        }

        struct Drive: Decodable {
            var vendor: String
            var product: String
            /// The time of the rip whose disc is in the drive. Nil for an empty drive.
            var disc: Date?
            var selected: Bool?
            var rip: Rip?
        }

        struct Rip: Decodable {
            /// The track being read; nil for a finished rip.
            var track: Int?
            /// How far through `track` the read is.
            var fraction: Double?
            /// Seconds since the rip started, or the time a finished rip took.
            var elapsed: Double?
            /// The drive's speed over 1×.
            var speed: Double?
        }

        var historyUntil: Date?
        var window: Window?
        var drives: [Drive]?
        /// The earlier rip to show, by its time.
        var rip: Date?
        /// The set to show, by the start of its title.
        var set: String?
        /// True shows the table of every rip.
        var history: Bool?
        /// How far to scroll.
        enum Scroll: Decodable, Equatable {
            /// The main window's table, to its last row.
            case bottom
            /// The front window's scrolling content, this many points down from where it starts.
            case points(Double)

            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let points = try? container.decode(Double.self) {
                    self = .points(points)
                } else if try container.decode(String.self) == "bottom" {
                    self = .bottom
                } else {
                    throw DecodingError.dataCorruptedError(
                        in: container, debugDescription: "scroll is \"bottom\" or a number of points")
                }
            }
        }

        var scroll: Scroll?
        /// Presses of Tab in the front window, as by hand, to give a control the focus (with
        /// keyboard navigation on in System Settings): 3 for About's Leave a Tip.
        var tabs: Int?
        /// True opens every row of the window's outline: a set's discs.
        var expand: Bool?
        /// False makes the main window invisible, for a screenshot of another window or of a
        /// sheet with the desktop around it.
        var mainWindow: Bool?

        /// The scene that `-scene` names, if any.
        static let current: ScreenshotScene? = {
            guard let path = UserDefaults.standard.string(forKey: "scene"), !path.isEmpty else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                return try decoder.decode(ScreenshotScene.self, from: Data(contentsOf: URL(filePath: path)))
            } catch {
                FileHandle.standardError.write(Data("scene: cannot read \(path): \(error)\n".utf8))
                exit(1)
            }
        }()

        /// The settings with the scene's `settings` keys changed, or nil if it changes none.
        static func settings(changing settings: Settings) -> Settings? {
            guard let path = UserDefaults.standard.string(forKey: "scene"),
                let data = try? Data(contentsOf: URL(filePath: path)),
                let scene = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let changes = scene["settings"] as? [String: Any], !changes.isEmpty,
                let encoded = try? JSONEncoder().encode(settings),
                var values = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            else { return nil }
            values.merge(changes) { $1 }
            guard let merged = try? JSONSerialization.data(withJSONObject: values),
                let changed = try? JSONDecoder().decode(Settings.self, from: merged)
            else {
                FileHandle.standardError.write(Data("scene: the settings do not take \(changes)\n".utf8))
                return nil
            }
            return changed
        }

        /// The user's history, read only: a scene runs with a scratch settings file, whose own
        /// history is empty.
        private static let history = RipHistory(
            directory: DriveProfileStore.defaultDirectory.appending(path: "History", directoryHint: .isDirectory))

        private static let entries = Array(history.entries().values)

        private static func entry(ripped date: Date) -> RipHistory.Entry? {
            let found = entries.first { abs($0.report.date.timeIntervalSince(date)) < 1 }
            if found == nil { FileHandle.standardError.write(Data("scene: no rip in the history at \(date)\n".utf8)) }
            return found
        }

        static func slotID(_ index: Int) -> String { "scene \(index)" }

        /// What the window shows: an earlier rip, a set, the history, or the selected drive.
        func selection(rips: [RecentRip], sets: [RipSet]) -> SidebarItem? {
            if let rip, let entry = Self.entry(ripped: rip) { return .rip(entry.key) }
            if let set, let found = sets.first(where: { $0.title.hasPrefix(set) }) { return .set(found.releaseID) }
            if history == true { return .history }
            return drives?.firstIndex { $0.selected == true }.map { .drive(Self.slotID($0)) }
        }

        /// The drives, each with its disc as it was read; the lookups and the rips follow.
        func slots() -> [DriveSlot] {
            (drives ?? []).enumerated().map { index, drive in
                let entry = drive.disc.flatMap(Self.entry(ripped:))
                let device = OpticalDrive(
                    vendor: drive.vendor, product: drive.product, revision: entry?.report.drive.revision ?? "",
                    interconnect: "USB", location: "External")
                guard let entry, let toc = try? TOC(ctdbTOCString: entry.report.toc) else {
                    return DriveSlot(id: Self.slotID(index), device: device)
                }
                let report = entry.report
                var disc = DiscInfo(bsdName: nil, toc: toc, mcn: report.mcn, cdText: report.cdText)
                disc.media = report.media
                disc.lookup = .lookingUp
                let slot = DriveSlot(id: Self.slotID(index), device: device, disc: disc) {
                    throw CocoaError(.featureUnsupported)
                }
                // What the look at the first tracks finds as the disc goes in.
                var probe = DiscProbe(cdGraphics: report.cdGraphics, tracksRead: min(3, report.tracks.count))
                for track in report.tracks.prefix(3) {
                    if let codes = track.hdcd { probe.hdcdCodes[track.number] = codes }
                }
                probe.hdcd = !probe.hdcdCodes.isEmpty
                slot.showScene(probe: probe)
                Task { @MainActor in
                    var looked = disc
                    await looked.lookUpRelease()
                    // A cache without the lookup: the release the rip had.
                    if looked.lookup != .found, let release = report.release { await looked.useSceneRelease(release) }
                    slot.disc = looked
                    guard let rip = drive.rip else { return }
                    let run = RipRun(disc: looked)
                    run.showScene(
                        report: report, folder: entry.url.deletingLastPathComponent(), track: rip.track,
                        fraction: rip.fraction ?? 0, elapsed: rip.elapsed, speed: rip.speed)
                    slot.rip = run
                }
                return slot
            }
        }

        /// The history as it was at `historyUntil`: of the rips whose report was at the same
        /// place, the newest then is there, and the others were replaced by it. A rip whose
        /// folder is gone since shows the folder of another rip of the disc, for its cover.
        func rips() -> RecentRip.Found {
            let then = Self.entries.filter { entry in historyUntil.map { entry.report.date <= $0 } ?? true }
            let newest = Dictionary(grouping: then) { $0.url.standardizedFileURL.path }
                .compactMapValues { $0.max { $0.report.date < $1.report.date } }
            let present = Array(newest.values)
            let keys = Set(present.map(\.key))
            var found = RecentRip.Found(present: present, offline: [], missing: then.filter { !keys.contains($0.key) })
            let manager = FileManager.default
            for index in found.present.indices where !manager.fileExists(atPath: found.present[index].folder.path) {
                let toc = found.present[index].report.toc
                if let other = Self.entries.first(where: {
                    $0.report.toc == toc && manager.fileExists(atPath: $0.url.deletingLastPathComponent().path)
                }) {
                    found.present[index].folder = other.url.deletingLastPathComponent()
                }
            }
            return found
        }

        /// The earlier rips' copies of the disc's tracks that AccurateRip says are accurate, from
        /// their reports, not their files, which can have changed since.
        static func earlierCopies(of toc: TOC, in rips: [RecentRip]) -> [Int: URL] {
            var copies = [Int: URL]()
            for rip in rips {
                for track in rip.report.tracks where track.accurateRip == .accurate && copies[track.number] == nil {
                    copies[track.number] = rip.folder
                }
            }
            return copies
        }

        /// False when the scene hides the sidebar.
        var showsSidebar: Bool { window?.sidebar ?? true }

        /// Gives the main window the scene's size, in the middle of the screen, in front of the
        /// Terminal that started the app, and opens and scrolls its table if the scene says so,
        /// or makes it invisible.
        func arrangeWindow() {
            NSApp.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let size = self.window, let window = Self.mainWindow else { return }
                var frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
                if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                    frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
                }
                window.setFrame(frame, display: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                // A finished rip's banner comes after the lookup, and the window's first button, an
                // info button by the chips, takes the focus, as a sheet's first link does: no view
                // has it in a screenshot. Again a little later, for a sheet that opens late.
                self.setFocus()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.setFocus() }
                // Its alpha, not its place on screen: a sheet stays on show with an invisible
                // window. Nor does it take the mouse, whose tooltips would show over the front one.
                if self.mainWindow == false {
                    Self.mainWindow?.alphaValue = 0
                    Self.mainWindow?.ignoresMouseEvents = true
                }
                if case .points(let points) = self.scroll, let view = Self.frontWindow?.contentView,
                    let scrollView = Self.scrollingView(in: view)
                {
                    let clip = scrollView.contentView
                    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + points))
                    scrollView.reflectScrolledClipView(clip)
                }
                guard let table = Self.mainWindow?.contentView.flatMap(Self.table(in:)) else { return }
                if self.expand == true { (table as? NSOutlineView)?.expandItem(nil, expandChildren: true) }
                if self.scroll == .bottom { table.scrollRowToVisible(table.numberOfRows - 1) }
            }
        }

        /// The main window: SwiftUI names it after its view.
        private static var mainWindow: NSWindow? {
            NSApp.windows.first { $0.identifier?.rawValue.contains("MainWindow") == true }
        }

        /// The window in front: the one a scene opens over the main window, else the main window.
        private static var frontWindow: NSWindow? {
            NSApp.windows.first { $0.isVisible && $0.alphaValue > 0 && $0 != mainWindow && $0.frame.width > 100 }
                ?? mainWindow
        }

        /// No view has the focus, unless the scene presses Tab, and the window in front is the key
        /// window, with its close button in color.
        private func setFocus() {
            for window in NSApp.windows where window.isVisible { window.makeFirstResponder(nil) }
            guard let window = Self.frontWindow else { return }
            if !window.isKeyWindow { window.makeKey() }
            for _ in 0..<(tabs ?? 0) { window.selectNextKeyView(nil) }
        }

        /// The first scroll view whose content is taller than it.
        private static func scrollingView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView, let document = scrollView.documentView,
                document.frame.height > scrollView.contentView.bounds.height + 1
            {
                return scrollView
            }
            for subview in view.subviews {
                if let found = scrollingView(in: subview) { return found }
            }
            return nil
        }

        private static func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for subview in view.subviews {
                if let table = table(in: subview) { return table }
            }
            return nil
        }
    }
#endif
