import DiskArbitration
import Foundation

/// Tells the model when a disc comes or goes, through DiskArbitration, on the main run loop: a
/// CD, and a DVD or Blu-ray disc, which the drive's page names; and when a DVD is mounted,
/// since its volume tells DVD-Audio from DVD-Video.
final class DiskWatcher {
    /// Touched by `deinit`, which is nonisolated; the session itself runs on the main run loop.
    private nonisolated(unsafe) let session: DASession?
    private let changed: () -> Void

    init(changed: @escaping () -> Void) {
        self.changed = changed
        session = DASessionCreate(kCFAllocatorDefault)
        guard let session else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for kind in ["IOCDMedia", "IODVDMedia", "IOBDMedia"] {
            let match = [kDADiskDescriptionMediaKindKey as String: kind] as CFDictionary
            DARegisterDiskAppearedCallback(session, match, DiskWatcher.diskChanged, context)
            DARegisterDiskDisappearedCallback(session, match, DiskWatcher.diskChanged, context)
            if kind != "IOCDMedia" {
                DARegisterDiskDescriptionChangedCallback(
                    session, match, [kDADiskDescriptionVolumePathKey] as CFArray, DiskWatcher.descriptionChanged,
                    context)
            }
        }
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

    private nonisolated static let descriptionChanged: DADiskDescriptionChangedCallback = { _, _, context in
        guard let context else { return }
        let watcher = Unmanaged<DiskWatcher>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { watcher.changed() }
    }
}
