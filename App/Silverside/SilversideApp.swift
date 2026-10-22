import SilversideKit
import SwiftUI

@main struct SilversideApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Silverside") {
            MainWindow()
                .environment(model)
        }
        .defaultSize(width: 1180, height: 760)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }

        Window("About Silverside", id: "about") {
            AboutView()
                .environment(model)
                .windowMinimizeBehavior(.disabled)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Window("Silverside Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 900, height: 620)
    }
}
