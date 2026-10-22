import CDRipDarwin
import CDRipKit
import SwiftUI

/// The main window: drives and earlier rips in the sidebar, and the selected disc or rip.
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailView()
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
        .onAppear {
            #if DEBUG
                DebugScreenshot.scheduleIfRequested()
                // `-openWindow help` opens a window at launch, for screenshots.
                if let id = UserDefaults.standard.string(forKey: "openWindow"), !id.isEmpty {
                    if id == "settings" { openSettings() } else { openWindow(id: id) }
                }
                // `-selectHistory 1` shows the rip history.
                if UserDefaults.standard.bool(forKey: "selectHistory") { model.selection = .history }
                // `-selectRecent 1` shows the newest earlier rip, for screenshots of the results;
                // with `-repair 1` too, its repair starts.
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
        if let slot = model.selectedDrive {
            DriveDetailView(slot: slot)
        } else if model.selection == .history {
            HistoryView()
        } else if let rip = model.selectedRip {
            ResultsView(folder: rip.folder, report: rip.report, hasAudio: rip.hasAudio)
        } else if model.drives.isEmpty {
            NoDriveView()
        } else {
            NoDiscView(driveName: nil)
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
                        .help("Every rip CDRip knows, in a table you can search and sort")
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
        case .reading: return "Reading the disc..."
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
            Text("Connect a CD, DVD, or Blu-ray drive. CDRip finds it as soon as macOS does.")
        }
    }
}
