import Foundation

/// Apple's Music app: encoded files go into its library, where they are, or copied into
/// Music's own folder if its "Copy files to Music Media folder when adding to Library"
/// setting is on. Silverside asks Music by Apple Events through `osascript`, so macOS asks
/// the user once to allow it. (Music's "Automatically Add to Music" folder is not used:
/// it moves the files out of the library.)
public enum MusicApp {
    /// Music reads every format Silverside writes but FLAC.
    public static func reads(_ format: AudioFormat) -> Bool { format != .flac }

    /// The script: the files come as arguments, so no path is ever read as AppleScript.
    static let script = """
        on run argv
            set theFiles to {}
            repeat with thePath in argv
                set end of theFiles to (POSIX file (contents of thePath)) as alias
            end repeat
            tell application "Music" to set added to add theFiles
            try
                if class of added is list then return count of added
            end try
            return count of theFiles
        end run
        """

    /// Adds the files to Music's library, and returns how many tracks Music added. It waits
    /// for Music, which may have to start, and for the user's answer the first time.
    @discardableResult
    public static func add(_ files: [URL]) throws -> Int {
        guard !files.isEmpty else { return 0 }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + files.map(\.path)
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            // errAEEventNotPermitted: the user said no, or has not been asked in this context.
            if message.contains("-1743") { throw MusicAppError.notAllowed }
            throw MusicAppError.failed(message)
        }
        return Int(String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            ?? files.count
    }
}

public enum MusicAppError: Error, Equatable, CustomStringConvertible {
    case notAllowed
    case failed(String)

    public var description: String {
        switch self {
        case .notAllowed:
            "Silverside may not control Music. Allow it in System Settings › Privacy & Security › Automation."
        case .failed(let message): "Music did not add the files: \(message)"
        }
    }
}
