import Foundation

/// Keeps the Mac awake for long work, such as a rip, while it lives: no idle sleep, and no App
/// Nap, which slows the reads and the encoding of an app whose windows do not show (the display
/// asleep, or the app hidden) to a crawl. The display may still sleep. A laptop whose lid is
/// closed sleeps all the same, on battery without an external display.
public final class KeepAwake: @unchecked Sendable {
    // ProcessInfo's activities may begin and end on any thread.
    private let activity: any NSObjectProtocol

    /// `reason` is for people: `pmset -g assertions` shows it.
    public init(_ reason: String) {
        // User-initiated work: no App Nap, and no idle system sleep.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: reason)
    }

    deinit { ProcessInfo.processInfo.endActivity(activity) }
}
