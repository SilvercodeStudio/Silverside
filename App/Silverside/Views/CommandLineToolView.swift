import SilversideKit
import SwiftUI

/// The Command Line Tool window (Silverside › Install Command Line Tool…): links the
/// `silverside` command in the app into a folder on the PATH, or takes the link away.
struct CommandLineToolView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    private var tool: CommandLineTool { model.commandLineTool }

    var body: some View {
        @Bindable var tool = tool
        VStack(alignment: .leading, spacing: 14) {
            Text("Command Line Tool").font(.title2.bold())
            Text(
                "The silverside command rips, repairs, checks, and encodes from Terminal, with the same settings. Silverside links it into a folder, with its completions for zsh, bash, and fish, so that each update of the app updates the command too."
            )
            .fixedSize(horizontal: false, vertical: true)
            Picker("Folder", selection: $tool.place) {
                Text("/usr/local/bin (may ask for your password)").tag(CommandLineTool.Place.usrLocal)
                Text("~/.local/bin").tag(CommandLineTool.Place.homeLocal)
            }
            .pickerStyle(.radioGroup)
            .disabled(tool.isWorking)
            if tool.isOnPath(tool.place) == false {
                Text(
                    "~/.local/bin is not on your shell's PATH. Add it in your shell's settings (for zsh, in ~/.zprofile: export PATH=\"$HOME/.local/bin:$PATH\"), or choose /usr/local/bin."
                )
                .font(.callout).foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text(status).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "In Terminal, silverside --help lists the commands, and silverside help rip (or any other command) explains one. The help has a page about the command too."
            )
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let error = tool.error {
                Text(error).font(.callout).foregroundStyle(Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                // The help's page about the command.
                HelpLink {
                    HelpPageRequest.shared.slug = "command-line-tool"
                    openWindow(id: "help")
                }
                if tool.isWorking { ProgressView().controlSize(.small) }
                if canRemove {
                    Button("Remove") { Task { await tool.removeCommand() } }
                        .disabled(tool.isWorking)
                }
                Spacer()
                Button("Done") { dismiss() }
                Button(tool.state(at: tool.place) == .linked ? "Install Again" : "Install") {
                    Task { await tool.installCommand() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(tool.isWorking || !tool.isAvailable)
            }
        }
        .padding(24)
        .frame(width: 480)
        .task { await tool.refresh() }
    }

    /// What is in the chosen folder now.
    private var status: String {
        let folder = tool.place.binFolder
        switch tool.state(at: tool.place) {
        case .missing:
            return "The command is not in \(folder)."
        case .linked:
            return "The command is installed in \(folder): type silverside in Terminal."
        case .linkedToOtherApp(let path):
            let gone = !FileManager.default.fileExists(atPath: path)
            return gone
                ? "\(folder)/silverside points to a copy of Silverside that was moved or deleted. Install links it to this one."
                : "\(folder)/silverside points to another copy of Silverside, at \(path). Install links it to this one."
        case .other:
            return
                "\(folder)/silverside is another file, such as a copy from make install. Install puts a link in its place."
        }
    }

    private var canRemove: Bool {
        switch tool.state(at: tool.place) {
        case .linked, .linkedToOtherApp: true
        case .missing, .other: false
        }
    }
}
