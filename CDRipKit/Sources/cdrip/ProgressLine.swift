import CDRipKit
import Foundation

/// One status line that changes in place, in a terminal: how far a track's read has come,
/// and whether the drive is finding errors. Nothing is shown when the output is a file.
final class ProgressLine {
    let isShown = isatty(STDOUT_FILENO) != 0
    /// Color for C2 errors (yellow) and unreadable sectors (red), unless NO_COLOR is set.
    let usesColor = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    /// The track, as "3/11". Setting it starts the track's clock.
    var label = "" {
        didSet { trackStart = .now }
    }
    private var lastDraw = ContinuousClock.now - .seconds(1)
    private var isOnScreen = false
    private var trackStart = ContinuousClock.now
    /// The read now under way, and when it started, for the time left.
    private var pass: (number: Int, start: ContinuousClock.Instant)?

    func show(_ event: RipEvent) {
        guard isShown else { return }
        let text: String
        switch event {
        case .reading(_, let number, let read, let sectors, let c2, let unreadable):
            if pass?.number != number { pass = (number, .now) }
            // At most 10 updates a second, but always the last one.
            guard read == sectors || ContinuousClock.now - lastDraw >= .milliseconds(100) else { return }
            let fraction = sectors == 0 ? 0 : Double(read) / Double(sectors)
            let filled = Int(fraction * 25)
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 25 - filled)
            var parts = [
                String(format: "[%@] %3d%%", bar, Int(fraction * 100)),
                number == 1 ? "read 1" : "read \(number) to compare",
            ]
            if c2 > 0 { parts.append(color("C2: \(c2) sectors", code: 33)) }
            if unreadable > 0 { parts.append(color("cannot read: \(unreadable) sectors", code: 31)) }
            var times = Self.minutes(ContinuousClock.now - trackStart)
            // The time left in this read, from its speed so far.
            if let pass, read > 0, read < sectors {
                let spent = ContinuousClock.now - pass.start
                times += ", " + Self.minutes(spent * (Double(sectors - read) / Double(read))) + " left"
            }
            parts.append(times)
            text = parts.joined(separator: "  ·  ")
        case .rereading(_, let round, let maximum, let suspects, let versions):
            pass = nil
            text =
                "re-reading \(suspects) suspect sectors  ·  round \(round) of \(maximum)  ·  \(versions) versions  ·  "
                + Self.minutes(ContinuousClock.now - trackStart)
        }
        draw("Track \(label)  " + text)
    }

    /// A time as "1:05".
    static func minutes(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Takes the line away, before a line that stays.
    func clear() {
        guard isOnScreen else { return }
        print("\r\u{1B}[2K", terminator: "")
        fflush(stdout)
        isOnScreen = false
    }

    private func draw(_ text: String) {
        print("\r\u{1B}[2K" + text, terminator: "")
        fflush(stdout)
        isOnScreen = true
        lastDraw = .now
    }

    private func color(_ text: String, code: Int) -> String {
        usesColor ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }
}
