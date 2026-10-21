import CDRipDarwin
import CDRipKit
import Foundation
import Observation

/// One drive in the sidebar: the hardware, the disc in it, and its rip.
@Observable
final class DriveSlot: Identifiable {
    enum DiscState: Equatable {
        /// No disc, or a disc that is not an audio CD.
        case empty
        case reading
        case ready
        case failed(String)
    }

    let id: String
    private(set) var device: OpticalDrive
    private(set) var discState = DiscState.empty
    private(set) var disc: DiscInfo?
    /// The tracks to rip, by number.
    var selectedTracks: Set<Int> = []
    /// Read each track once, with no re-reads.
    var fastMode = false
    var rip: RipRun?
    /// Makes the engine's drive for a rip, on the rip's thread.
    let makeDrive: @Sendable () throws -> any CDDrive
    let isDemo: Bool
    /// The disc the `disc` was read from, so a swapped disc is read again.
    @ObservationIgnored private var discBSDName: String?
    @ObservationIgnored private var readTask: Task<Void, Never>?

    init(id: String, device: OpticalDrive) {
        self.id = id
        self.device = device
        isDemo = false
        let name = device.discBSDName ?? ""
        makeDrive = { try IOKitDrive(bsdName: name) }
    }

    /// A slot with a drive of its own, such as the demo's simulated drive.
    init(id: String, device: OpticalDrive, disc: DiscInfo, makeDrive: @escaping @Sendable () throws -> any CDDrive) {
        self.id = id
        self.device = device
        self.disc = disc
        self.makeDrive = makeDrive
        isDemo = true
        discState = .ready
        selectedTracks = Set(disc.toc.audioTracks.map(\.number))
    }

    static func baseID(of device: OpticalDrive) -> String {
        "\(device.vendor) \(device.product) \(device.revision) \(device.interconnect) \(device.location)"
    }

    var name: String { "\(device.vendor) \(device.product)".trimmingCharacters(in: .whitespaces) }

    var identity: DriveIdentity {
        DriveIdentity(vendor: device.vendor, product: device.product, revision: device.revision)
    }

    /// Nil without a disc, or while a rip holds the drive.
    var needsDisc: Bool {
        !isDemo && device.discBSDName != discBSDName && rip?.isRunning != true
    }

    func update(_ device: OpticalDrive) {
        self.device = device
        if device.discBSDName == nil, !isDemo {
            disc = nil
            discState = .empty
            discBSDName = nil
            readTask?.cancel()
            // A finished rip stays on show until the next disc.
            if rip?.isRunning == true { rip?.stop() }
        }
    }

    /// Reads the disc's TOC, MCN, and CD-Text, then looks up the release and its cover.
    func readDisc(settings: Settings) {
        guard let bsdName = device.discBSDName, rip?.isRunning != true else { return }
        discBSDName = bsdName
        discState = .reading
        disc = nil
        rip = nil
        let make = makeDrive
        readTask?.cancel()
        readTask = Task { @MainActor in
            do {
                let read = try await DiscInfo.read(makeDrive: make, bsdName: bsdName)
                guard !Task.isCancelled else { return }
                var info = DiscInfo(bsdName: bsdName, toc: read.toc, mcn: read.mcn, cdText: read.cdText)
                disc = info
                selectedTracks = Set(info.toc.audioTracks.map(\.number))
                discState = .ready
                await info.lookUpRelease()
                guard !Task.isCancelled else { return }
                disc = info
            } catch {
                discState = .failed("\(error)")
            }
        }
    }

    /// Uses another of the releases that have the disc.
    func choose(_ release: MusicBrainzRelease) {
        guard var info = disc else { return }
        Task { @MainActor in
            await info.choose(release)
            disc = info
        }
    }

    func lookUpAgain() {
        guard var info = disc else { return }
        Task { @MainActor in
            await info.lookUpRelease()
            disc = info
        }
    }
}
