#if DEBUG
    import AppKit
    import Foundation

    /// Debug aid: `-screenshotPath /path/shot.png -screenshotDelay 4` renders every visible
    /// window to PNG files after the delay (the main window to the path, the others with
    /// -2, -3 added), then quits. It draws the view hierarchy, so it needs no screen
    /// recording permission. `-screenshotWidth 700` makes the main window that wide first, to
    /// check a narrow layout.
    enum DebugScreenshot {
        private static var scheduled = false

        static func scheduleIfRequested() {
            guard !scheduled, let path = UserDefaults.standard.string(forKey: "screenshotPath"), !path.isEmpty else {
                return
            }
            scheduled = true
            let configured = UserDefaults.standard.double(forKey: "screenshotDelay")
            let delay = configured > 0 ? configured : 4
            let width = UserDefaults.standard.double(forKey: "screenshotWidth")
            if width > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + max(delay - 1.5, 0.5)) {
                    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 100 }) else {
                        return
                    }
                    var frame = window.frame
                    frame.size.width = width
                    window.setFrame(frame, display: true)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                capture(to: URL(fileURLWithPath: path))
                // A plain exit: terminate(nil) waits while a sheet or a repair is up, and this is a debug aid.
                exit(0)
            }
        }

        static func capture(to url: URL) {
            let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 100 }
            for (offset, window) in windows.enumerated() {
                guard let view = window.contentView?.superview ?? window.contentView else { continue }
                let scale = window.backingScaleFactor
                let size = view.bounds.size
                guard
                    let rep = NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                        pixelsHigh: Int(size.height * scale),
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                    let context = NSGraphicsContext(bitmapImageRep: rep)
                else { continue }
                // Layers draw what the table views and materials put on screen; cacheDisplay leaves them out.
                view.layoutSubtreeIfNeeded()
                context.cgContext.scaleBy(x: scale, y: scale)
                view.layer?.render(in: context.cgContext)
                guard let data = rep.representation(using: .png, properties: [:]) else { continue }
                let target =
                    offset == 0 ? url : url.deletingPathExtension().appendingPathExtension("\(offset + 1).png")
                do {
                    try data.write(to: target)
                    FileHandle.standardError.write(Data("screenshot: \(target.path)\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("screenshot: \(error)\n".utf8))
                }
            }
        }
    }
#endif
