import SilversideDarwin
import SilversideKit
import SwiftUI

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Silverside") { openWindow(id: "about") }
        }
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .help) {
            Button("Silverside Help") { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
            Button("Welcome to Silverside") { openWindow(id: "welcome") }
            Divider()
            Button("Silverside Website") { NSWorkspace.shared.open(AboutView.website) }
        }
        CommandGroup(after: .sidebar) {
            Button("Rip History") { model.selection = .history }
                .keyboardShortcut("y", modifiers: .command)
            Divider()
            Button("Back", action: model.goBack)
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.canGoBack)
            Button("Forward", action: model.goForward)
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.canGoForward)
        }
        CommandMenu("Disc") {
            Button("Rip") { if let slot = model.selectedDrive { model.startRip(slot) } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!canRip)
            Button("Stop Rip") { if let slot = model.selectedDrive { model.stopRip(slot) } }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model.selectedDrive?.rip?.isRunning != true)
            Divider()
            Button("Look Up Metadata") { model.selectedDrive?.lookUpAgain() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(model.selectedDrive?.disc == nil)
            Button("New Release in MusicBrainz…") {
                if let disc = model.selectedDrive?.disc, let release = disc.release {
                    ResultChips.openNewRelease(copying: release, toc: disc.toc)
                }
            }
            .disabled(!canAddNewRelease)
            Button("Save Data Track…") {
                if let (rip, number) = model.dataTrackToSave { model.saveDataTrack(number, of: rip) }
            }
            .disabled(model.dataTrackToSave == nil)
            Button("Show Rip Log") { model.logShown = true }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model.selectedDrive?.rip == nil)
            Divider()
            Button("Repair Rip…") { if let rip = model.selectedRip { model.startRepair(rip) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!canRepair)
            Button("Change Release…") { model.changingRelease = model.selectedRip }
                .disabled(model.selectedRip.map(model.canChangeRelease) != true)
            Divider()
            Button("Eject") { if let slot = model.selectedDrive { model.eject(slot) } }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.selectedDrive?.device.discBSDName == nil)
            Button("Refresh Drives") { model.refreshDrives() }
        }
    }

    /// A release that MusicBrainz found by the disc ID. One matched by its track lengths needs
    /// the disc ID attached instead, and a disc MusicBrainz does not know has Add to MusicBrainz.
    private var canAddNewRelease: Bool {
        guard let disc = model.selectedDrive?.disc, let release = disc.release else { return false }
        return !release.isManual && !release.lacksDiscID(of: disc.toc)
    }

    private var canRip: Bool {
        guard let slot = model.selectedDrive, slot.disc != nil else { return false }
        return slot.rip?.isRunning != true && !slot.isBusy && !slot.selectedTracks.isEmpty
    }

    private var canRepair: Bool {
        guard let rip = model.selectedRip else { return false }
        return !rip.isVerified && rip.report.ctdb.status != .notInDatabase && model.repair?.isRunning != true
    }
}
