import SilversideDarwin
import SilversideKit
import SwiftUI

/// The main window: drives and earlier rips in the sidebar, and the selected disc or rip.
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    /// A rip that waits to hear whether to replace files in the library.
    private var questionRip: RipRun? { model.drives.lazy.compactMap(\.rip).first { $0.overwriteQuestion != nil } }
    /// A rip that waits to hear whether to decode its HDCD codes.
    private var hdcdRip: RipRun? { model.drives.lazy.compactMap(\.rip).first { $0.hdcdQuestion != nil } }
    /// A rip that waits to hear whether to de-emphasize its tracks with pre-emphasis.
    private var preEmphasisRip: RipRun? {
        model.drives.lazy.compactMap(\.rip).first { $0.preEmphasisQuestion != nil }
    }

    private static func message(for question: RipRun.OverwriteQuestion) -> String {
        let files = question.existing.count == 1 ? "1 file" : "\(question.existing.count) files"
        let folder = question.folder.map { " in \(($0.path as NSString).abbreviatingWithTildeInPath)" } ?? ""
        return "The library already has \(files) of “\(question.album)”\(folder). Replace them with this rip?\n\n"
            + "If you keep them, nothing is encoded, and the rip stays in the rips folder."
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailView()
                .alert(
                    "Replace the files in the library?",
                    isPresented: Binding(get: { questionRip != nil }, set: { _ in }),
                    presenting: questionRip
                ) { rip in
                    Button("Replace", role: .destructive) { rip.answer(replaces: true) }
                    Button("Keep the Files", role: .cancel) { rip.answer(replaces: false) }
                } message: { rip in
                    if let question = rip.overwriteQuestion { Text(Self.message(for: question)) }
                }
        }
        .frame(minWidth: 980, minHeight: 600)
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { _ in
            Button("OK") {}
        } message: { alert in
            Text(alert.message)
        }
        .sheet(isPresented: $model.logShown) {
            RipLogView(run: model.selectedDrive?.rip)
        }
        .sheet(isPresented: $model.repairShown) {
            if let run = model.repair { RepairSheet(run: run) }
        }
        .sheet(isPresented: Binding(get: { hdcdRip != nil }, set: { _ in })) {
            if let rip = hdcdRip, let question = rip.hdcdQuestion { HDCDQuestionSheet(rip: rip, question: question) }
        }
        .sheet(isPresented: Binding(get: { preEmphasisRip != nil }, set: { _ in })) {
            if let rip = preEmphasisRip, let question = rip.preEmphasisQuestion {
                PreEmphasisQuestionSheet(rip: rip, question: question)
            }
        }
        .sheet(isPresented: $model.libraryShown) {
            if let run = model.library { LibrarySheet(run: run) }
        }
        .onAppear {
            // The first launch opens the welcome. `-welcomeDone 0` opens it again, and `-welcomeDone 1` keeps it shut.
            if !UserDefaults.standard.bool(forKey: WelcomeView.doneKey) { openWindow(id: "welcome") }
            #if DEBUG
                DebugScreenshot.scheduleIfRequested()
                // `-openWindow help` opens a window at launch, for screenshots.
                if let id = UserDefaults.standard.string(forKey: "openWindow"), !id.isEmpty {
                    if id == "settings" { openSettings() } else { openWindow(id: id) }
                }
                // `-selectHistory 1` shows the rip history; `-selectSet 1` the first multi-disc set,
                // and `-selectSetTitle Dozin` the first whose title starts so.
                if UserDefaults.standard.bool(forKey: "selectHistory") { model.selection = .history }
                let setTitle = UserDefaults.standard.string(forKey: "selectSetTitle")
                if UserDefaults.standard.bool(forKey: "selectSet") || setTitle != nil {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1))
                        if let set = model.sets.first(where: { setTitle.map($0.title.hasPrefix) ?? true }) {
                            model.selection = .set(set.releaseID)
                        }
                    }
                }
                // `-selectRecent 1` shows the newest earlier rip, for screenshots of the results;
                // with `-repair 1` too, its repair starts, and with `-hdcdDecode 1`, Decode HDCD opens.
                if UserDefaults.standard.bool(forKey: "selectRecent") {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1))
                        guard let rip = model.recentRips.first else { return }
                        model.selection = .rip(rip.file)
                        if UserDefaults.standard.bool(forKey: "repair") { model.startRepair(rip) }
                    }
                }
            #endif
        }
    }
}

/// The right side: the selected drive's disc, or an earlier rip's results.
struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let slot = model.selectedDrive {
                DriveDetailView(slot: slot)
            } else if model.selection == .history {
                HistoryView()
            } else if let set = model.selectedSet {
                SetView(ripSet: set)
            } else if let rip = model.selectedRip {
                ResultsView(folder: rip.folder, report: rip.report, hasAudio: rip.hasAudio, reportFile: rip.file)
                    .id(rip.file)
            } else if model.drives.isEmpty {
                NoDriveView()
            } else {
                NoDiscView(driveName: nil)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { PlayerBar(player: model.player) }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: model.goBack) { Label("Back", systemImage: "chevron.backward") }
                    .disabled(!model.canGoBack)
                    .help("Show the place you were before (⌘[ or ⌘←)")
                Button(action: model.goForward) { Label("Forward", systemImage: "chevron.forward") }
                    .disabled(!model.canGoForward)
                    .help("Show the place you went back from (⌘] or ⌘→)")
            }
        }
        .background(BackKeys(model: model))
    }
}

/// ⌘← and ⌘→ go back and forward in the main window, as in Safari, except in a text field,
/// where they move the insertion point. The View menu has ⌘[ and ⌘].
private struct BackKeys: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> KeyView { KeyView(model: model) }
    func updateNSView(_ view: KeyView, context: Context) {}

    final class KeyView: NSView {
        private let model: AppModel
        private var monitor: Any?

        init(model: AppModel) {
            self.model = model
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                    event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
                        == .command,
                    !(window.firstResponder is NSText)
                else { return event }
                switch event.keyCode {
                case 123 where model.canGoBack: model.goBack()
                case 124 where model.canGoForward: model.goForward()
                default: return event
                }
                return nil
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// The newest rips the sidebar lists; the rest are in the history.
    static let recentCount = 8

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Drives") {
                if model.drives.isEmpty {
                    Text("No optical drive").foregroundStyle(.secondary)
                }
                ForEach(model.drives) { slot in
                    SidebarRow(
                        title: slot.name, subtitle: subtitle(of: slot), systemImage: icon(of: slot),
                        tone: tone(of: slot)
                    )
                    .tag(SidebarItem.drive(slot.id))
                }
            }
            Section("Recent Rips") {
                if model.recentRips.isEmpty {
                    Text("No rips yet").foregroundStyle(.secondary)
                }
                ForEach(model.recentRips.prefix(Self.recentCount)) { rip in
                    SidebarRow(
                        title: rip.title, subtitle: rip.subtitle,
                        systemImage: rip.isVerified ? "checkmark.circle" : "exclamationmark.triangle",
                        tone: rip.isVerified ? .good : .warning
                    )
                    .tag(SidebarItem.rip(rip.file))
                    .help(rip.details)
                }
                if model.recentRips.count > Self.recentCount || model.selection == .history {
                    Label("All Rips (\(model.recentRips.count))", systemImage: "clock")
                        .tag(SidebarItem.history)
                        .help("Every rip Silverside knows, in a table you can search and sort")
                }
            }
            if !model.sets.isEmpty {
                Section("Sets") {
                    ForEach(model.sets, id: \.releaseID) { set in
                        SidebarRow(
                            title: set.title,
                            subtitle: set.isComplete
                                ? "\(set.discCount) discs" : "\(set.discs.count) of \(set.discCount) discs",
                            systemImage: "square.stack", tone: set.isComplete ? .good : .neutral
                        )
                        .tag(SidebarItem.set(set.releaseID))
                        .help(set.summary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 360)
        .safeAreaInset(edge: .bottom) {
            Button {
                model.revealFolder(model.settings.ripsURL)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(model.settings.rips).lineLimit(1).truncationMode(.middle)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the rips folder in the Finder")
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func subtitle(of slot: DriveSlot) -> String {
        if let rip = slot.rip, rip.isRunning { return "Ripping · \(Int(rip.fraction * 100))%" }
        switch slot.discState {
        case .empty: return "No disc"
        case .reading: return "Reading the disc…"
        case .failed: return "Cannot read the disc"
        case .ready:
            guard let disc = slot.disc else { return "" }
            let count = disc.toc.audioTracks.count
            return "\(disc.title) · \(count) track\(count == 1 ? "" : "s")"
        }
    }

    private func icon(of slot: DriveSlot) -> String {
        slot.disc == nil ? "opticaldiscdrive" : "opticaldisc"
    }

    private func tone(of slot: DriveSlot) -> Chip.Tone {
        if let rip = slot.rip, rip.isRunning { return .good }
        return slot.disc == nil ? .neutral : .good
    }
}

struct SidebarRow: View {
    var title: String
    var subtitle: String
    var systemImage: String
    var tone: Chip.Tone

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
    }

    private var color: Color {
        switch tone {
        case .neutral: .secondary
        case .good: Theme.good
        case .warning: Theme.warning
        case .bad: Theme.bad
        }
    }
}

/// The main window before a disc is loaded.
struct NoDiscView: View {
    var driveName: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 180, height: 180)
            Text("Insert an audio CD").font(.title2.weight(.semibold))
            Text(driveName.map { "\($0) is empty." } ?? "Choose a drive in the sidebar.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NoDriveView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No optical drive", systemImage: "opticaldiscdrive")
        } description: {
            Text("Connect a CD, DVD, or Blu-ray drive. Silverside finds it as soon as macOS does.")
        }
    }
}
