import CDRipDarwin
import SwiftUI

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .help) {
            Button("CDRip Help") { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
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
            Button("Show Rip Log") { model.logShown = true }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model.selectedDrive?.rip == nil)
            Divider()
            Button("Eject") { if let slot = model.selectedDrive { model.eject(slot) } }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.selectedDrive?.device.discBSDName == nil)
            Button("Refresh Drives") { model.refreshDrives() }
        }
    }

    private var canRip: Bool {
        guard let slot = model.selectedDrive, slot.disc != nil else { return false }
        return slot.rip?.isRunning != true && !slot.selectedTracks.isEmpty
    }
}
