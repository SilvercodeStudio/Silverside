import Foundation
import SilversideKit

/// Install Command Line Tool…: links the `silverside` command in the app, and its shell
/// completions, into a folder on the PATH (`CommandLineInstall`). Only a Release build has the
/// command (the build phase "Put the command line tool in the app").
@Observable
final class CommandLineTool {
    /// The folders it can go in.
    enum Place: String, CaseIterable, Identifiable {
        /// On every shell's PATH; needs an administrator's password, unless the folders are the user's.
        case usrLocal
        /// Needs no password, but may not be on the PATH.
        case homeLocal

        var id: Self { self }

        var prefix: URL {
            switch self {
            case .usrLocal: URL(filePath: "/usr/local", directoryHint: .isDirectory)
            case .homeLocal: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local")
            }
        }

        /// The command's folder, as the user would type it.
        var binFolder: String {
            switch self {
            case .usrLocal: "/usr/local/bin"
            case .homeLocal: "~/.local/bin"
            }
        }
    }

    let app = Bundle.main.bundleURL
    let isAvailable = CommandLineInstall.hasCommand(inApp: Bundle.main.bundleURL)
    var place = Place.usrLocal
    private(set) var isWorking = false
    var error: String?
    /// The folders on the PATH of the user's shell, nil until known, or if the shell did not say.
    private(set) var shellPath: [String]?
    /// Goes up when the links change, so that views read their state again.
    private(set) var version = 0

    func install(at place: Place) -> CommandLineInstall {
        CommandLineInstall(app: app, prefix: place.prefix)
    }

    /// The command's state in a folder. Reading `version` makes a view read it again after a change.
    func state(at place: Place) -> CommandLineInstall.State {
        _ = version
        return install(at: place).commandState
    }

    /// True if the folder is on the shell's PATH, nil if that is not known.
    func isOnPath(_ place: Place) -> Bool? {
        guard place == .homeLocal else { return true }
        guard let shellPath else { return nil }
        let folder = place.prefix.appending(path: "bin").standardizedFileURL.path
        return shellPath.contains { URL(filePath: $0).standardizedFileURL.path == folder }
    }

    /// Why the app cannot link the command where it is now, if it cannot: an app that macOS runs
    /// from a hidden copy (one opened from Downloads and not moved), or from a disk image.
    var placeProblem: String? {
        let readOnly = (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
        guard readOnly || app.path.contains("/AppTranslocation/") else { return nil }
        return "Move Silverside to the Applications folder, open it from there, then install the command."
    }

    /// Looks up the shell's PATH, and chooses the folder: the one that has the command, else
    /// ~/.local/bin if it is on the PATH, else /usr/local/bin.
    func refresh() async {
        version += 1
        if shellPath == nil { shellPath = await Task.detached { Self.readShellPath() }.value }
        if let installed = Place.allCases.first(where: { state(at: $0) == .linked }) {
            place = installed
        } else {
            place = isOnPath(.homeLocal) == true ? .homeLocal : .usrLocal
        }
    }

    func installCommand() async {
        if let placeProblem {
            error = placeProblem
            return
        }
        await run(install(at: place).installScript)
    }

    func removeCommand() async {
        guard let script = install(at: place).removeScript else { return }
        await run(script)
    }

    /// Runs the script as the user, and for /usr/local, if that fails, as an administrator, which
    /// asks for a password.
    private func run(_ script: String) async {
        isWorking = true
        error = nil
        let (asAdministrator, folder) = (place == .usrLocal, place.binFolder)
        let result = await Task.detached { () -> String? in
            if (try? Self.shell(script)) == true { return nil }
            guard asAdministrator else { return "The command could not be linked into \(folder)." }
            return Self.shellAsAdministrator(script)
        }.value
        error = result
        isWorking = false
        version += 1
    }

    /// True if `/bin/sh -c script` succeeds.
    nonisolated private static func shell(_ script: String) throws -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Runs the script with an administrator's rights, through AppleScript's `do shell script`,
    /// which asks for the password. Nil if it worked or the user cancelled, else the error.
    nonisolated private static func shellAsAdministrator(_ script: String) -> String? {
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return "\(error)"
        }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if process.terminationStatus == 0 || message.contains("(-128)") { return nil }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The PATH of the user's login shell, as Terminal would have it, from the shell itself (a
    /// login and interactive one, so that its startup files run). Nil if it does not answer in a
    /// few seconds.
    nonisolated private static func readShellPath() -> [String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "SILVERSIDE-PATH:"
        let print =
            shell.hasSuffix("/fish")
            ? "printf '\\n\(marker)%s' (string join : $PATH)" : "printf '\\n\(marker)%s' \"$PATH\""
        let process = Process()
        process.executableURL = URL(filePath: shell)
        process.arguments = ["-l", "-i", "-c", print]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        guard (try? process.run()) != nil else { return nil }
        let timer = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: marker, options: .backwards) else { return nil }
        let path = text[range.upperBound...].trimmingCharacters(in: .newlines)
        return path.split(separator: ":").map(String.init)
    }
}
