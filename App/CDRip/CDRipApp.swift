import CDRipKit
import SwiftUI

@main struct CDRipApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("CDRip") {
            MainWindow()
                .environment(model)
        }
        .defaultSize(width: 1180, height: 760)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
