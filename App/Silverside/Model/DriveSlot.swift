import Foundation
import Observation
import SilversideDarwin
import SilversideKit

/// Choices for the next rip only, as `silverside rip` has them: the folder, the pool, offline.
struct RipChoices: Equatable {
    /// The rip's folder. Nil names it from the release, in the rips folder.
    var folder: URL?
    /// Pool the earlier rips of the disc with this one.
    var poolsEarlierRips = true
    /// Look nothing up: no AccurateRip, CTDB, or drive offset list.
    var offline = false
}

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
    /// Views change its edits; the slot sets the rest.
    var disc: DiscInfo?
    /// The tracks to rip, by number.
    var selectedTracks: Set<Int> = []
    /// Read each track once, with no re-reads. Kept between launches.
    var fastMode = UserDefaults.standard.bool(forKey: "fastMode") {
        didSet { UserDefaults.standard.set(fastMode, forKey: "fastMode") }
    }
    /// Choices for the next rip. The folder is forgotten with the disc.
    var choices = RipChoices()
    /// True while a repair or a drive test holds the drive.
    var isBusy = false
    /// Which names the header and the table show.
    var namesSource = DiscInfo.Source.musicBrainz
    var rip: RipRun?
    /// With "rip it at once" on, for a disc that just went in: the rip starts at this time
    /// unless the user cancels it (`AppModel.considerRipOnInsert`).
    var ripOnInsertDate: Date?
    /// Why a disc that just went in was not ripped at once: "several releases have this disc".
    var ripOnInsertNote: String?
    /// A drive of the slot's own, such as the demo's simulated drive.
    private let customDrive: (@Sendable () throws -> any CDDrive)?
    let isDemo: Bool
    /// The disc the `disc` was read from, so a swapped disc is read again.
    /// Names typed in the drive page and not yet accepted, for a rip that starts first.
    @ObservationIgnored let pendingNames = PendingNames()
    @ObservationIgnored private var discBSDName: String?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    /// What a short look at the disc's audio found, as it was read (`DiscProbe`); nil until then.
    private(set) var probe: DiscProbe?
    @ObservationIgnored private var probeStop: StopToken?

    init(id: String, device: OpticalDrive) {
        self.id = id
        self.device = device
        isDemo = false
        customDrive = nil
    }

    /// A slot with a drive of its own, such as the demo's simulated drive.
    init(id: String, device: OpticalDrive, disc: DiscInfo, makeDrive: @escaping @Sendable () throws -> any CDDrive) {
        self.id = id
        self.device = device
        self.disc = disc
        customDrive = makeDrive
        isDemo = true
        discState = .ready
        selectedTracks = Set(disc.toc.audioTracks.map(\.number))
    }

    static func baseID(of device: OpticalDrive) -> String {
        "\(device.vendor) \(device.product) \(device.revision) \(device.interconnect) \(device.location)"
    }

    /// Makes the engine's drive for the disc in the drive now, on the caller's thread.
    var makeDrive: @Sendable () throws -> any CDDrive {
        if let customDrive { return customDrive }
        let name = device.discBSDName ?? ""
        return { try IOKitDrive(bsdName: name) }
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
            ripOnInsertDate = nil
            ripOnInsertNote = nil
            readTask?.cancel()
            stopProbe()
            probe = nil
            // A finished rip stays on show until the next disc.
            if rip?.isRunning == true { rip?.stop() }
        }
    }

    /// Reads the disc's TOC, MCN, and CD-Text, then looks up the release and its cover.
    /// `looked` hears when the lookup is done.
    func readDisc(settings: Settings, then looked: (@MainActor () -> Void)? = nil) {
        guard let bsdName = device.discBSDName, rip?.isRunning != true else { return }
        discBSDName = bsdName
        discState = .reading
        disc = nil
        rip = nil
        choices.folder = nil
        ripOnInsertDate = nil
        ripOnInsertNote = nil
        let make = makeDrive
        readTask?.cancel()
        stopProbe()
        probe = nil
        readTask = Task { @MainActor in
            do {
                let read = try await DiscInfo.read(makeDrive: make, bsdName: bsdName)
                guard !Task.isCancelled else { return }
                var info = DiscInfo(bsdName: bsdName, toc: read.toc, mcn: read.mcn, cdText: read.cdText)
                info.media = read.media
                // The lookup changes its own copy, so the one on show says it is under way.
                if !info.toc.audioTracks.isEmpty { info.lookup = .lookingUp }
                disc = info
                selectedTracks = Set(info.toc.audioTracks.map(\.number))
                discState = .ready
                startProbe(make, toc: info.toc)
                await info.lookUpRelease()
                guard !Task.isCancelled else { return }
                disc = info
                looked?()
            } catch {
                discState = .failed("\(error)")
            }
        }
    }

    /// Looks at a few seconds of the first tracks, for the disc's logo, while the lookup runs.
    private func startProbe(_ make: @escaping @Sendable () throws -> any CDDrive, toc: TOC) {
        guard !toc.audioTracks.isEmpty else { return }
        let stop = StopToken()
        probeStop = stop
        Task { @MainActor in
            let found = await Task.detached { (try? make()).map { DiscProbe.probe($0, toc: toc, stop: stop) } }.value
            guard !stop.isStopped else { return }
            probe = found
        }
    }

    /// Stops the look at the audio, so that a rip has the drive to itself.
    func stopProbe() {
        probeStop?.stop()
        probeStop = nil
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
        disc?.lookup = .lookingUp
        Task { @MainActor in
            await info.lookUpRelease(fresh: true)
            disc = info
        }
    }
}
