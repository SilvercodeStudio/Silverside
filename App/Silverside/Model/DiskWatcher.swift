import DiskArbitration
import Foundation

/// Tells the model when a CD comes or goes, through DiskArbitration, on the main run loop.
final class DiskWatcher {
    /// Touched by `deinit`, which is nonisolated; the session itself runs on the main run loop.
    private nonisolated(unsafe) let session: DASession?
    private let changed: () -> Void

    init(changed: @escaping () -> Void) {
        self.changed = changed
        session = DASessionCreate(kCFAllocatorDefault)
        guard let session else { return }
        let match = [kDADiskDescriptionMediaKindKey as String: "IOCDMedia"] as CFDictionary
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, match, DiskWatcher.diskChanged, context)
        DARegisterDiskDisappearedCallback(session, match, DiskWatcher.diskChanged, context)
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        if let session {
            DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
    }

    private nonisolated static let diskChanged: DADiskAppearedCallback = { _, context in
        guard let context else { return }
        let watcher = Unmanaged<DiskWatcher>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { watcher.changed() }
    }
}
