import Foundation
import Observation
import SilversideKit

/// One rip of a disc, as the engine reports it, for the track table, the progress bar, and the log.
@Observable
final class RipRun {
    enum Phase: Equatable {
        case starting
        case ripping
        case checkingCTDB
        case encoding
        case finished
        case stopped
        case failed(String)
    }

    /// Where a track is in its rip.
    enum TrackState: Equatable {
        case queued
        /// A read of the whole track: pass 1 is the first read, later passes compare.
        case reading(pass: Int, fraction: Double)
        case rereading(round: Int, maximumRounds: Int, suspectSectors: Int)
        case finished(RipReport.Track)
        case skipped
    }

    /// The sectors of a track that the drive flagged, could not read, or that reads disagree on,
    /// counted from the track's start, for the error strip.
    struct TrackErrors: Equatable {
        var sectors: Int
        var flagged: Set<Int> = []
        var unreadable: Set<Int> = []
        var suspect: Set<Int> = []
        var unresolved: Set<Int> = []
        var isEmpty: Bool { flagged.isEmpty && unreadable.isEmpty && suspect.isEmpty && unresolved.isEmpty }
    }

    private(set) var phase = Phase.starting
    private(set) var trackStates: [Int: TrackState] = [:]
    private(set) var trackErrors: [Int: TrackErrors] = [:]
    private(set) var summaries: [Int: String] = [:]
    /// The track being read, its position among the tracks to rip, and their count.
    private(set) var currentTrack: Int?
    private(set) var position = 0
    private(set) var count = 0
    private(set) var log: [String] = []
    private(set) var folder: URL?
    private(set) var readOffset: Int?
    private(set) var offsetSource: String?
    private(set) var accurateRipRecords: Int?
    private(set) var ctdbEntries: Int?
    private(set) var report: RipReport?
    private(set) var ctdb: RipReport.CTDBResult?
    private(set) var repairedTracks: [Int: Int] = [:]
    private(set) var result: DiscRipResult?
    private(set) var encodedFiles: [URL] = []
    /// Tracks encoded so far, for the progress bar while encoding.
    private(set) var encodedCount = 0
    private(set) var encodingFormat: AudioFormat?
    private(set) var startDate = Date()
    private(set) var endDate: Date?
    /// Sectors read so far, over every track to rip, for the whole-rip progress.
    private(set) var sectorsDone = 0
    private(set) var sectorsInPass = 0
    private(set) var sectorsTotal = 0
    /// The drive's speed, from the current pass: sectors per second over 1× (75).
    private(set) var speed: Double?

    let disc: DiscInfo
    /// Hears each step of progress, for the Dock tile.
    @ObservationIgnored var onProgress: (@MainActor () -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var passStart: (date: Date, sectors: Int)?
    @ObservationIgnored private var tracksToRip: [Int] = []
    @ObservationIgnored private var sectorsBefore: [Int: Int] = [:]

    init(disc: DiscInfo) {
        self.disc = disc
    }

    var isRunning: Bool {
        switch phase {
        case .starting, .ripping, .checkingCTDB, .encoding: true
        case .finished, .stopped, .failed: false
        }
    }

    var elapsed: TimeInterval { (endDate ?? Date()).timeIntervalSince(startDate) }

    /// The fraction of the whole rip's sectors read in the first pass.
    var fraction: Double {
        guard sectorsTotal > 0 else { return 0 }
        return min(1, Double(sectorsDone + sectorsInPass) / Double(sectorsTotal))
    }

    /// The fraction of the tracks encoded, while encoding.
    var encodeFraction: Double {
        guard !tracksToRip.isEmpty else { return 0 }
        return min(1, Double(encodedCount) / Double(tracksToRip.count))
    }

    var secondsLeft: Int? {
        guard let speed, speed > 0, sectorsTotal > sectorsDone + sectorsInPass else { return nil }
        return Int(Double(sectorsTotal - sectorsDone - sectorsInPass) / (speed * Double(CDDA.sectorsPerSecond)))
    }

    /// Starts the rip on a thread of its own. The engine's events come back on the main queue, in order.
    func start(
        makeDrive: @escaping @Sendable () throws -> any CDDrive, identity: DriveIdentity, settings: Settings,
        options: DiscRipOptions, encodes: Bool, onFinish: @escaping @MainActor () -> Void
    ) {
        tracksToRip = options.tracks ?? disc.toc.audioTracks.map(\.number)
        for track in disc.toc.audioTracks {
            trackStates[track.number] = tracksToRip.contains(track.number) ? .queued : .skipped
            trackErrors[track.number] = TrackErrors(sectors: disc.toc.sectorRange(of: track).count)
        }
        var before = 0
        for track in disc.toc.audioTracks where tracksToRip.contains(track.number) {
            sectorsBefore[track.number] = before
            before += disc.toc.sectorRange(of: track).count
        }
        sectorsTotal = before
        startDate = Date()
        let run = self
        task = Task.detached {
            do {
                let drive = try makeDrive()
                var rip = DiscRip(
                    drive: drive, identity: identity, settings: settings, options: options,
                    profiles: try DriveProfileStore())
                if encodes { rip.encoder = DiscEncoder(settings: settings) }
                rip.events = { event in
                    DispatchQueue.main.async { MainActor.assumeIsolated { run.handle(event) } }
                }
                let result = try await rip.run()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        run.result = result
                        run.end(.finished)
                        onFinish()
                    }
                }
            } catch is CancellationError {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        run.end(.stopped)
                        onFinish()
                    }
                }
            } catch {
                let message = RipRun.message(for: error)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        run.add("Failed: \(message)")
                        run.end(.failed(message))
                        onFinish()
                    }
                }
            }
        }
    }

    /// The engine's errors, worded for the app where they name the CLI.
    nonisolated static func message(for error: any Error) -> String {
        if case DiscRipError.unknownOffset(let drive) = error {
            return
                "The read offset of \(drive) is not known. Silverside looks it up in AccurateRip's drive list when it is online, or set it in Settings › Drives."
        }
        return "\(error)"
    }

    /// Stops after the read under way. The tracks ripped so far stay in the folder.
    func stop() {
        guard isRunning else { return }
        add("Stopping after the read under way...")
        task?.cancel()
    }

    private func end(_ phase: Phase) {
        endDate = Date()
        self.phase = phase
        currentTrack = nil
        for (number, state) in trackStates {
            if case .finished = state { continue }
            if state != .skipped { trackStates[number] = .queued }
        }
        switch phase {
        case .stopped: add("Stopped." + (folder.map { " The tracks ripped so far are in \($0.path)." } ?? ""))
        case .finished: add("Done.")
        default: break
        }
    }

    private func add(_ line: String) {
        log.append(line)
    }

    /// The text that the status bar shows.
    var statusText: String {
        switch phase {
        case .starting: return "Starting..."
        case .ripping:
            guard let currentTrack else { return "Ripping..." }
            var text = "Ripping track \(currentTrack)" + (count > 1 ? " (\(position) of \(count))" : "")
            switch trackStates[currentTrack] {
            case .reading(let pass, _) where pass > 1: text += " · read \(pass)"
            case .rereading(let round, let maximum, let suspects):
                text += " · re-reading \(Format.count(suspects, "sector")), round \(round) of \(maximum)"
            default: break
            }
            return text
        case .checkingCTDB: return "Checking the disc against CUETools DB..."
        case .encoding:
            let format = encodingFormat?.rawValue.uppercased() ?? ""
            return "Encoding as \(format) · track \(min(encodedCount + 1, tracksToRip.count)) of \(tracksToRip.count)"
        case .finished:
            if let report { return RipRun.headline(for: report) }
            return "Done"
        case .stopped: return "Stopped"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    /// "All 6 tracks ripped accurately", or what is not right.
    static func headline(for report: RipReport) -> String {
        let total = report.tracks.count
        let verified = report.tracks.filter { track in
            track.accurateRip == .accurate || track.accurateRip == .otherPressings || (track.ctdbConfidence ?? 0) > 0
                || report.ctdb.status == .verified || report.ctdb.status == .repaired
        }.count
        if verified == total {
            return total == 1 ? "The track ripped accurately" : "All \(total) tracks ripped accurately"
        }
        if verified == 0, report.tracks.allSatisfy({ $0.accurateRip == .notInDatabase }),
            report.ctdb.status != .notVerified
        {
            return "\(total) tracks ripped, but no database can check this disc"
        }
        return "\(verified) of \(total) tracks verified"
    }

    // MARK: Events

    private func handle(_ event: DiscRipEvent) {
        switch event {
        case .disc:
            phase = .ripping
        case .drive(let drive, let offset, let source):
            readOffset = offset
            offsetSource = source
            add(
                "Drive: \(drive.name) (firmware \(drive.revision)), read offset \(offset.signedDescription) (\(source))"
            )
        case .lookupFailed(let lookup, let error):
            add("\(lookup.rawValue): the lookup failed (\(error)). The rip goes on without it.")
        case .lookups(let records, let ctdb):
            accurateRipRecords = records
            ctdbEntries = ctdb?.entries
            add(
                "AccurateRip: "
                    + (records.map { $0 == 0 ? "disc not in the database" : "\($0) records" } ?? "not checked"))
            add(
                "CTDB: "
                    + (ctdb.map {
                        $0.entries == 0
                            ? "disc not in the database"
                            : "\($0.entries) entries, up to \($0.mostSubmissions) submissions"
                    } ?? "not checked"))
        case .release(let lookup):
            if let chosen = lookup?.chosen {
                add("MusicBrainz: " + chosen.summary(for: disc.toc))
            } else if lookup != nil {
                add("MusicBrainz: no release has this disc")
            }
        case .releaseLookupFailed(let error):
            add("MusicBrainz: the lookup failed (\(error))")
        case .folder(let folder, let insteadOf):
            self.folder = folder
            add("Folder: \(folder.path)" + (insteadOf.map { _ in " (another rip holds the usual folder)" } ?? ""))
        case .hiddenTrack(let hidden):
            add(
                "Hidden track before track 1: \(Format.duration(sectors: hidden.sectors)), "
                    + (hidden.readsAgree ? "\(hidden.reads) reads agree" : "NOT verified: \(hidden.reads) reads differ")
            )
        case .poolFileSkipped(let file):
            add("Pool: \(file.url.lastPathComponent) was not used: \(file.reason).")
        case .trackStarted(let track, let position, let count):
            currentTrack = track.number
            self.position = position
            self.count = count
            sectorsDone = sectorsBefore[track.number] ?? sectorsDone
            sectorsInPass = 0
            trackStates[track.number] = .reading(pass: 1, fraction: 0)
            passStart = (Date(), 0)
        case .reading(let event):
            handle(event)
        case .trackFinished(let track, let summary, let seconds):
            trackStates[track.number] = .finished(track)
            summaries[track.number] = summary
            trackErrors[track.number]?.suspect.formUnion(track.suspectSectors)
            trackErrors[track.number]?.unresolved.formUnion(track.unresolvedSectors)
            sectorsDone = (sectorsBefore[track.number] ?? 0) + track.sectors
            sectorsInPass = 0
            onProgress?()
            add(
                String(format: "Track %2d  %@  %d s  ", track.number, Format.duration(sectors: track.sectors), seconds)
                    + summary)
        case .checkingCTDB:
            phase = .checkingCTDB
            currentTrack = nil
            add("Checking the disc against CUETools DB...")
        case .repairLog(let line):
            add(line)
        case .repaired(let repair):
            ctdb = RipReport.CTDBResult(repair)
            phase = .ripping
        case .trackRepaired(let number, let samples, let accurateRip):
            repairedTracks[number] = samples
            var line = String(format: "  Track %2d  %d samples repaired", number, samples)
            switch accurateRip {
            case .accurate(let v1, let v2): line += "  AccurateRip: accurate (v1 \(v1), v2 \(v2) submissions)"
            case .notAccurate: line += "  AccurateRip: NOT accurate"
            case .notChecked: break
            }
            add(line)
        case .ctdbNotChecked:
            add("CTDB: not checked, because it checks the whole disc, and some tracks were not ripped.")
        case .finished(let report, _, _):
            self.report = report
            ctdb = report.ctdb
            for track in report.tracks { trackStates[track.number] = .finished(track) }
            add(RipRun.headline(for: report))
        case .artwork(let result):
            switch result {
            case .saved(let files): add("Cover: saved \(files.count == 1 ? "cover.jpg" : "\(files.count) images")")
            default: add("Cover: \(result)")
            }
        case .artworkFailed(let error):
            add("Cover: the download failed (\(error))")
        case .encoding(let format):
            phase = .encoding
            encodingFormat = format
            encodedCount = 0
            onProgress?()
            add("Encoding as \(format.rawValue.uppercased())...")
        case .encodedTrack(let line):
            encodedCount += 1
            onProgress?()
            add("  \(line)")
        case .encoded(let files, let format):
            encodedFiles = files
            add("Encoded \(files.count) tracks as \(format.rawValue.uppercased()), each checked against the rip.")
        case .ripDeleted:
            add("Deleted the rip's WAV files. The rip report is in the album folder.")
        case .ripKept(let folder):
            add("Kept the rip in \(folder.path): not every track is verified and encoded.")
        }
    }

    private func handle(_ event: RipEvent) {
        switch event {
        case .reading(let track, let pass, let progress):
            let fraction = progress.sectors > 0 ? Double(progress.sectorsRead) / Double(progress.sectors) : 0
            trackStates[track] = .reading(pass: pass, fraction: fraction)
            if pass == 1 {
                sectorsInPass = min(progress.sectorsRead, trackErrors[track]?.sectors ?? progress.sectorsRead)
            }
            trackErrors[track]?.flagged.formUnion(progress.flaggedInChunk)
            trackErrors[track]?.unreadable.formUnion(progress.unreadableInChunk)
            onProgress?()
            if let passStart {
                let seconds = Date().timeIntervalSince(passStart.date)
                if progress.chunk.lowerBound <= 0 || progress.sectorsRead < passStart.sectors {
                    self.passStart = (Date(), progress.sectorsRead)
                } else if seconds > 1.5 {
                    speed = Double(progress.sectorsRead - passStart.sectors) / seconds / Double(CDDA.sectorsPerSecond)
                }
            } else {
                passStart = (Date(), progress.sectorsRead)
            }
        case .rereading(let track, let round, let maximum, let suspects, _):
            trackStates[track] = .rereading(round: round, maximumRounds: maximum, suspectSectors: suspects.count)
            trackErrors[track]?.suspect.formUnion(suspects)
        }
    }
}
