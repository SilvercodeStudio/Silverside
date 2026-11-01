import DiscRecording
import DiskArbitration
import Foundation

public enum DiscEjectError: Error, Equatable, CustomStringConvertible {
    case noDisk(String)
    /// Disc Recording does not know the drive, or the drive would not eject or open.
    case noDrive(String)
    case driveRefused(String)
    /// DiskArbitration refused a step ("unmount" or "eject"), with its status code.
    case refused(bsdName: String, step: String, status: Int32, reason: String?)

    public var description: String {
        switch self {
        case .noDisk(let name): "There is no disc \(name)."
        case .noDrive(let name): "macOS's Disc Recording does not know the drive \(name)."
        case .driveRefused(let name): "\(name) would not eject its disc or open its tray."
        case .refused(let name, let step, let status, let reason):
            "Cannot \(step) \(name): " + (reason ?? String(format: "status 0x%08X", UInt32(bitPattern: status)))
                + (status == Int32(truncatingIfNeeded: kDAReturnBusy) ? " (a program is using it)" : "")
        }
    }
}

/// Ejects a disc through DiskArbitration, as the Finder does: first it unmounts the disc's
/// volumes (cddafs mounts every audio CD), then it ejects the disc.
public enum DiscEject {
    /// What `ejectDrive` did.
    public enum DriveResult: Sendable {
        case ejected
        case trayOpened
    }

    /// Whether a drive has a disc, by Disc Recording: also a disc that macOS did not
    /// recognize, so it has no BSD name (a promo that kept the drive spinning, 2026-10-31).
    /// Nil if Disc Recording does not know the drive. It asks the drive's state, and does not read the disc.
    public static func hasMedia(registryPath: String) -> Bool? {
        guard let device = DRDevice(forIORegistryEntryPath: registryPath),
            let state = device.status()?[DRDeviceMediaStateKey] as? String
        else { return nil }
        return state != DRDeviceMediaStateNone
    }

    /// Ejects the disc from a drive through Disc Recording, as `drutil eject` does, for a disc
    /// that has no BSD name for DiskArbitration; with no disc, it opens the tray.
    public static func ejectDrive(registryPath: String, name: String) throws -> DriveResult {
        guard let device = DRDevice(forIORegistryEntryPath: registryPath) else { throw DiscEjectError.noDrive(name) }
        if hasMedia(registryPath: registryPath) != false, device.ejectMedia() { return .ejected }
        guard device.openTray() else { throw DiscEjectError.driveRefused(name) }
        return .trayOpened
    }

    public static func eject(bsdName: String) async throws {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { throw DiscEjectError.noDisk(bsdName) }
        let queue = DispatchQueue(label: "Silverside.DiscEject")
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else {
            throw DiscEjectError.noDisk(bsdName)
        }
        do {
            try await run("unmount", bsdName) {
                DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), callback, $0)
            }
        } catch DiscEjectError.refused(_, _, let status, _)
            // The constants are negative Ints in Swift: UInt32(_:) of one traps.
            where status == Int32(truncatingIfNeeded: kDAReturnNotMounted)
        {
            // Nothing was mounted.
        }
        try await run("eject", bsdName) {
            DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), callback, $0)
        }
    }

    /// The result of one DiskArbitration request, which calls back on the session's queue.
    private final class Request: @unchecked Sendable {
        let continuation: CheckedContinuation<Void, any Error>
        let step: String
        let bsdName: String

        init(_ continuation: CheckedContinuation<Void, any Error>, step: String, bsdName: String) {
            self.continuation = continuation
            self.step = step
            self.bsdName = bsdName
        }
    }

    private static func run(_ step: String, _ bsdName: String, start: (UnsafeMutableRawPointer) -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            start(Unmanaged.passRetained(Request(continuation, step: step, bsdName: bsdName)).toOpaque())
        }
    }

    /// For both unmount and eject: a dissenter means that the step was refused.
    private static let callback: @convention(c) (DADisk, DADissenter?, UnsafeMutableRawPointer?) -> Void = {
        _, dissenter, context in
        guard let context else { return }
        let request = Unmanaged<Request>.fromOpaque(context).takeRetainedValue()
        guard let dissenter else {
            request.continuation.resume()
            return
        }
        request.continuation.resume(
            throwing: DiscEjectError.refused(
                bsdName: request.bsdName, step: request.step, status: DADissenterGetStatus(dissenter),
                reason: DADissenterGetStatusString(dissenter) as String?))
    }
}
