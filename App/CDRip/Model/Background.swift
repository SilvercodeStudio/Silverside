import AppKit
import UserNotifications

/// The Dock tile shows how far the rips are, for a rip that runs behind another app.
enum DockProgress {
    private static let view = DockProgressView()

    /// Shows the fraction on the Dock tile, or the plain icon again for nil.
    static func show(_ fraction: Double?) {
        let tile = NSApp.dockTile
        guard let fraction else {
            guard tile.contentView != nil else { return }
            tile.contentView = nil
            tile.display()
            return
        }
        // Half a percent at a time: the tile is small, and a redraw on every chunk is waste.
        let rounded = (min(max(fraction, 0), 1) * 200).rounded() / 200
        if tile.contentView == nil { tile.contentView = view }
        guard view.fraction != rounded else { return }
        view.fraction = rounded
        tile.display()
    }
}

/// The app icon with a progress bar along its bottom edge.
final class DockProgressView: NSView {
    var fraction = 0.0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        let inset = bounds.width * 0.14
        let bar = NSRect(
            x: inset, y: bounds.height * 0.1, width: bounds.width - 2 * inset, height: bounds.height * 0.11)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
        let fill = bar.insetBy(dx: 1.5, dy: 1.5)
        let done = NSRect(x: fill.minX, y: fill.minY, width: fill.width * fraction, height: fill.height)
        NSColor.systemGreen.setFill()
        NSBezierPath(roundedRect: done, xRadius: done.height / 2, yRadius: done.height / 2).fill()
    }
}

/// Tells the user that a rip is done when the app is behind another: the Dock icon
/// bounces, and a notification says how the rip went. Nothing happens while the app is in front.
enum RipNotifier {
    static func ripFinished(title: String, body: String) {
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
        // Notifications need an app bundle; a bare executable has none.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        Task {
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else { return }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                try await center.add(
                    UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            } catch {
                // A refused or failed notification is no reason to bother the user twice.
            }
        }
    }
}
