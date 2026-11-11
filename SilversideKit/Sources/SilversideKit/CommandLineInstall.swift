import Foundation

/// The `silverside` command inside the app (`Contents/Helpers/silverside`) and its shell completions
/// (`Contents/Resources/Completions`), linked into a folder on the PATH: the app's Install Command
/// Line Tool…. Links, not copies, so that an update of the app (Sparkle replaces it in place)
/// updates the command too. The layout under the prefix is `make install`'s.
public struct CommandLineInstall: Sendable, Equatable {
    public struct Link: Sendable, Equatable {
        /// The file in the app.
        public var source: URL
        /// The link under the prefix.
        public var destination: URL
        /// The source's path inside an app, such as "Contents/Helpers/silverside", to know a link
        /// to another copy of the app.
        public var pathInApp: String
    }

    /// What is at a link's place.
    public enum State: Sendable, Equatable {
        case missing
        /// A link to this app's file.
        case linked
        /// A link to the same file in another copy of the app, or in one that was moved or deleted.
        case linkedToOtherApp(String)
        /// A file, a folder, or a link to something else: such as `make install`'s copy.
        case other
    }

    public let app: URL
    public let prefix: URL
    /// The command first, then the zsh, bash, and fish completions.
    public let links: [Link]

    public init(app: URL, prefix: URL) {
        self.app = app
        self.prefix = prefix
        let places = [
            (Self.commandInApp, "bin/silverside"),
            ("Contents/Resources/Completions/_silverside", "share/zsh/site-functions/_silverside"),
            ("Contents/Resources/Completions/silverside.bash", "etc/bash_completion.d/silverside"),
            ("Contents/Resources/Completions/silverside.fish", "share/fish/vendor_completions.d/silverside.fish"),
        ]
        links = places.map { inApp, underPrefix in
            Link(
                source: app.appending(path: inApp), destination: prefix.appending(path: underPrefix),
                pathInApp: inApp)
        }
    }

    /// The command's place in the app.
    public static let commandInApp = "Contents/Helpers/silverside"

    /// The command's link.
    public var command: Link { links[0] }

    /// True if the app has the command: a Release build does.
    public static func hasCommand(inApp app: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: app.appending(path: commandInApp).path)
    }

    public static func state(of link: Link) -> State {
        let path = link.destination.path
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            var info = stat()
            return lstat(path, &info) == 0 ? .other : .missing
        }
        let resolved = URL(filePath: target, relativeTo: link.destination.deletingLastPathComponent())
            .standardizedFileURL.path
        if resolved == link.source.standardizedFileURL.path { return .linked }
        return resolved.hasSuffix(".app/" + link.pathInApp) ? .linkedToOtherApp(resolved) : .other
    }

    /// The state of the command's link.
    public var commandState: State { Self.state(of: command) }

    /// Shell commands that make every link, in place of what is there, for `/bin/sh -c`.
    public var installScript: String {
        links.map { link in
            let folder = link.destination.deletingLastPathComponent().path
            return "mkdir -p \(Self.quoted(folder)) && ln -sfn \(Self.quoted(link.source.path)) "
                + Self.quoted(link.destination.path)
        }
        .joined(separator: " && ")
    }

    /// Shell commands that remove the links to this app or another copy of it, or nil if there are
    /// none. A copy, or another program's file, stays.
    public var removeScript: String? {
        let paths = links.filter {
            switch Self.state(of: $0) {
            case .linked, .linkedToOtherApp: true
            case .missing, .other: false
            }
        }
        guard !paths.isEmpty else { return nil }
        return "rm -f " + paths.map { Self.quoted($0.destination.path) }.joined(separator: " ")
    }

    /// A word for `sh`: in single quotes, with each single quote closed, escaped, and opened again.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
