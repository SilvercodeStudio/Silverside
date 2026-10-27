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
        /// A read of the whole track: pass 1 is the first read, later passes compare, up to `passes`.
        case reading(pass: Int, passes: Int, fraction: Double)
        case rereading(round: Int, maximumRounds: Int, suspectSectors: Int)
        /// The test read of test and copy, after the rip's own reads.
        case testing(fraction: Double)
        case finished(RipReport.Track)
        case skipped
    }

    /// Where a track is in the encoding after the rip.
    enum EncodeState: Equatable {
        case queued
        case encoding
        case encoded(URL)
        /// Not encoded: the files in the library were kept, or the rip stopped first.
        case notEncoded
        case failed
    }

    /// The library already has files of the disc: the rip waits for `answer(replaces:)`.
    struct OverwriteQuestion: Identifiable {
        let id = UUID()
        var existing: [URL]
        var album: String
        var folder: URL? { existing.first?.deletingLastPathComponent() }
    }

    /// The rip found HDCD codes that change the audio: it waits for `answerHDCD(decodes:)`.
    struct HDCDQuestion: Identifiable {
        let id = UUID()
        var album: String
        /// What the codes ask for: "peak extend in every track; gain down to -3.0 dB in track 8".
        var features: String?
        var format: AudioFormat
        var recommendsDecoding: Bool { format.recommendsHDCDDecode }
    }

    /// The rip found tracks with pre-emphasis: it waits for `answerPreEmphasis(deEmphasizes:)`.
    struct PreEmphasisQuestion: Identifiable {
        let id = UUID()
        var album: String
        /// "tracks 1-11, 28-29 (23 of 99)"
        var tracks: String
        var everyTrack: Bool
        var format: AudioFormat
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
    /// What the CTDB check is doing now, from its log, while it runs.
    private(set) var ctdbStatus: String?
    /// True while the rip waits for the artwork download at the end.
    private(set) var isSavingArtwork = false
    /// The data track being saved as an ISO image, after the audio, and how much of it is read.
    private(set) var dataTrackProgress: (number: Int, fraction: Double)?
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
    /// True if the rip encodes into the library when it ends.
    private(set) var encodes = false
    private(set) var encodeStates: [Int: EncodeState] = [:]
    /// The files that the library already had and the user kept, so the rip was not encoded.
    private(set) var keptFiles: [URL]?
    /// What became of adding the files to Music: "Added 12 tracks to Music", or why not.
    private(set) var musicResult: String?
    /// True if the encoded files go into Music.
    private(set) var addsToMusic = false
    private(set) var overwriteQuestion: OverwriteQuestion?
    private(set) var hdcdQuestion: HDCDQuestion?
    private(set) var preEmphasisQuestion: PreEmphasisQuestion?
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
    @ObservationIgnored private var overwriteAnswer: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var hdcdAnswer: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var preEmphasisAnswer: CheckedContinuation<Bool, Never>?
    /// Hears the question about files in the library, so the app can show the drive and ask for attention.
    @ObservationIgnored var onQuestion: (@MainActor () -> Void)?

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

    /// True while the current track is being read again, re-read, or test-read: time the
    /// estimate does not count.
    var isRereading: Bool {
        guard let currentTrack else { return false }
        switch trackStates[currentTrack] {
        case .reading(let pass, _, _): return pass > 1
        case .rereading, .testing: return true
        default: return false
        }
    }

    var secondsLeft: Int? {
        guard let speed, speed > 0, sectorsTotal > sectorsDone + sectorsInPass else { return nil }
        return Int(Double(sectorsTotal - sectorsDone - sectorsInPass) / (speed * Double(CDDA.sectorsPerSecond)))
    }

    /// Starts the rip on a thread of its own. The engine's events come back on the main queue, in order.
    func start(
        makeDrive: @escaping @Sendable () throws -> any CDDrive, identity: DriveIdentity, settings: Settings,
        options: DiscRipOptions, encodes: Bool, allowsUnverified: Bool = false, library: URL? = nil,
        onFinish: @escaping @MainActor () -> Void
    ) {
        self.encodes = encodes
        addsToMusic = encodes && options.addsToMusic && MusicApp.reads(settings.format)
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
        add("Rip started.")
        let run = self
        task = Task.detached {
            do {
                let drive = try makeDrive()
                var rip = DiscRip(
                    drive: drive, identity: identity, settings: settings, options: options,
                    profiles: try DriveProfileStore())
                if encodes {
                    var encoder = DiscEncoder(settings: settings)
                    encoder.allowsUnverified = allowsUnverified
                    rip.encoder = encoder
                    if let library { rip.library = library }
                }
                rip.events = { event in
                    DispatchQueue.main.async { MainActor.assumeIsolated { run.handle(event) } }
                }
                rip.confirmOverwrite = { existing in
                    await withCheckedContinuation { continuation in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { run.ask(existing, answer: continuation) }
                        }
                    }
                }
                rip.chooseHDCD = { report, format in
                    await withCheckedContinuation { continuation in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { run.askHDCD(report, format: format, answer: continuation) }
                        }
                    }
                }
                rip.choosePreEmphasis = { report, format in
                    await withCheckedContinuation { continuation in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                run.askPreEmphasis(report, format: format, answer: continuation)
                            }
                        }
                    }
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
        switch error {
        case DiscRipError.unknownOffset(let drive):
            return
                "The read offset of \(drive) is not known. Silverside looks it up in AccurateRip's drive list when it is online, or set it in Settings › Drives."
        case EncodingError.notVerified(let track):
            return
                "Not encoded: track \(track) is not verified by AccurateRip or CTDB. The rip is in the rips folder."
        case EncodingError.exists(let file):
            return "Not encoded: \(file.path) is already in the library. The rip is in the rips folder."
        default:
            return "\(error)"
        }
    }

    /// Stops after the read under way. The tracks ripped so far stay in the folder.
    func stop() {
        guard isRunning else { return }
        add("Stopping after the read under way...")
        task?.cancel()
        // A rip that waits for the question stops when it hears the answer.
        if overwriteQuestion != nil { answer(replaces: false) }
        if hdcdQuestion != nil { answerHDCD(decodes: false) }
        if preEmphasisQuestion != nil { answerPreEmphasis(deEmphasizes: false) }
    }

    private func askHDCD(_ report: RipReport, format: AudioFormat, answer: CheckedContinuation<Bool, Never>) {
        hdcdAnswer = answer
        hdcdQuestion = HDCDQuestion(album: disc.title, features: HDCDStatus.features(of: report.tracks), format: format)
        add("HDCD codes that change the audio. Waiting for an answer: decode them, or keep the audio as pressed...")
        onQuestion?()
    }

    /// Answers the HDCD question: true decodes the codes.
    func answerHDCD(decodes: Bool) {
        guard let hdcdAnswer else { return }
        self.hdcdAnswer = nil
        hdcdQuestion = nil
        add(
            decodes
                ? "Decoding the HDCD codes." : "Keeping the audio as pressed, with its HDCD codes.")
        hdcdAnswer.resume(returning: decodes)
    }

    private func askPreEmphasis(_ report: RipReport, format: AudioFormat, answer: CheckedContinuation<Bool, Never>) {
        preEmphasisAnswer = answer
        preEmphasisQuestion = PreEmphasisQuestion(
            album: disc.title, tracks: report.preEmphasisTracks ?? "",
            everyTrack: report.tracks.allSatisfy(\.preEmphasis), format: format)
        add("Tracks with pre-emphasis. Waiting for an answer: de-emphasize them, or keep the audio as pressed...")
        onQuestion?()
    }

    /// Answers the pre-emphasis question: true takes the pre-emphasis out.
    func answerPreEmphasis(deEmphasizes: Bool) {
        guard let preEmphasisAnswer else { return }
        self.preEmphasisAnswer = nil
        preEmphasisQuestion = nil
        add(deEmphasizes ? "De-emphasizing the tracks with pre-emphasis." : "Keeping the audio as pressed.")
        preEmphasisAnswer.resume(returning: deEmphasizes)
    }

    private func ask(_ existing: [URL], answer: CheckedContinuation<Bool, Never>) {
        overwriteAnswer = answer
        overwriteQuestion = OverwriteQuestion(existing: existing, album: disc.title)
        add("The library already has \(Format.count(existing.count, "file")) of this disc. Waiting for an answer...")
        onQuestion?()
    }

    /// Answers the question about files in the library: true replaces them, false keeps them and the rip.
    func answer(replaces: Bool) {
        guard let overwriteAnswer else { return }
        self.overwriteAnswer = nil
        overwriteQuestion = nil
        add(replaces ? "Replacing the files in the library." : "Keeping the files in the library.")
        overwriteAnswer.resume(returning: replaces)
    }

    private func end(_ phase: Phase) {
        let wasEncoding = self.phase == .encoding
        endDate = Date()
        self.phase = phase
        for (number, state) in encodeStates {
            switch state {
            case .encoding: encodeStates[number] = wasEncoding && phase != .stopped ? .failed : .notEncoded
            case .queued: encodeStates[number] = .notEncoded
            default: break
            }
        }
        currentTrack = nil
        for (number, state) in trackStates {
            if case .finished = state { continue }
            if state != .skipped { trackStates[number] = .queued }
        }
        switch phase {
        case .stopped: add("Stopped." + (folder.map { " The tracks ripped so far are in \($0.path)." } ?? ""))
        case .finished: add("Done. The rip took \(Format.duration(seconds: Int(elapsed))).")
        default: break
        }
    }

    /// Each line starts with the time, so the log says when each track, the check, and the
    /// encoding finished.
    private func add(_ line: String) {
        log.append(Self.clock.string(from: Date()) + "  " + line)
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    @ObservationIgnored private var ctdbStarted: Date?

    /// The text that the status bar shows.
    var statusText: String {
        switch phase {
        case .starting: return "Starting…"
        case .ripping:
            if overwriteQuestion != nil { return "Waiting for your answer about the library…" }
            if hdcdQuestion != nil { return "Waiting for your answer about HDCD…" }
            if preEmphasisQuestion != nil { return "Waiting for your answer about pre-emphasis…" }
            // Between the last read and the encoding: the cover, the lookups' results, and the report.
            guard let currentTrack else {
                if isSavingArtwork { return "Saving the cover art…" }
                if let (number, fraction) = dataTrackProgress {
                    return "Saving data track \(number) · \(Int(fraction * 100))%"
                }
                return fraction >= 1 ? "Finishing the rip…" : "Ripping…"
            }
            var text = "Ripping track \(currentTrack)" + (count > 1 ? " (\(position) of \(count))" : "")
            switch trackStates[currentTrack] {
            case .reading(let pass, let passes, _) where pass > 1: text += " · read \(pass) of up to \(passes)"
            case .rereading(let round, let maximum, let suspects):
                text += " · re-reading \(Format.count(suspects, "sector")), round \(round) of \(maximum)"
            case .testing: text += " · test read"
            default: break
            }
            return text
        case .checkingCTDB: return ctdbStatus ?? "Checking the disc against CUETools DB…"
        case .encoding:
            if !encodedFiles.isEmpty {
                return addsToMusic && musicResult == nil ? "Adding the files to Music…" : "Finishing…"
            }
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
            add(SilversideVersion.program)
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
                if let failure = lookup?.detailsFailure {
                    add(
                        "MusicBrainz: the release's own lookup failed (\(failure)), so the files get no writers or genre"
                    )
                }
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
                    + ((hidden.unreadableSectors ?? []).isEmpty
                        ? "" : ", \(hidden.unreadableSectors!.count) sectors unreadable")
            )
        case .hiddenAreaUnreadable(let sectors, let total):
            add(
                "Before track 1: \(sectors) of \(total) sectors could not be read, and the rest is silence. "
                    + "This drive may not read before track 1; another drive may find a hidden track there.")
        case .poolFileSkipped(let file):
            add("Pool: \(file.url.lastPathComponent) was not used: \(file.reason).")
        case .trackStarted(let track, let position, let count):
            currentTrack = track.number
            self.position = position
            self.count = count
            sectorsDone = sectorsBefore[track.number] ?? sectorsDone
            sectorsInPass = 0
            trackStates[track.number] = .reading(pass: 1, passes: 1, fraction: 0)
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
        case .controlBits(let summary):
            add("Control bits: " + summary)
        case .savingDataTrack(let number, let fraction):
            if dataTrackProgress == nil { add("Data track \(number): saving it as an ISO image…") }
            dataTrackProgress = (number, fraction)
        case .dataTrackSaved(let track):
            dataTrackProgress = nil
            add(RipReport.dataTrackSummary(track))
        case .dataTrackFailed(let number, let message):
            dataTrackProgress = nil
            add("Data track \(number): not saved: \(message)")
        case .checkingCTDB:
            phase = .checkingCTDB
            currentTrack = nil
            ctdbStarted = Date()
            add("Checking the disc against CUETools DB...")
        case .repairLog(let line):
            add(line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            ctdbStatus = "CUETools DB: " + trimmed.prefix(1).lowercased() + trimmed.dropFirst()
        case .repaired(let repair):
            ctdb = RipReport.CTDBResult(repair)
            ctdbStatus = nil
            if let ctdbStarted {
                add("CTDB: done in \(Format.duration(seconds: Int(Date().timeIntervalSince(ctdbStarted)))).")
            }
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
        case .savingArtwork:
            isSavingArtwork = true
        case .artwork(let result):
            isSavingArtwork = false
            switch result {
            case .saved(let files):
                add("Cover: saved \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) images")")
            default: add("Cover: \(result)")
            }
        case .artworkFailed(let error):
            isSavingArtwork = false
            add("Cover: the download failed (\(error))")
        case .encoding(let format):
            phase = .encoding
            encodingFormat = format
            encodedCount = 0
            for number in tracksToRip { encodeStates[number] = .queued }
            startNextEncode()
            onProgress?()
            add("Encoding as \(format.rawValue.uppercased())...")
        case .encodedTrack(let line):
            add("  \(line)")
        case .trackEncoded(let number, let file):
            encodedCount += 1
            encodeStates[number] = .encoded(file)
            startNextEncode()
            onProgress?()
        case .encodingDeclined(let existing):
            keptFiles = existing
            for number in tracksToRip { encodeStates[number] = .notEncoded }
            add("Not encoded: the library keeps its files. The rip is in \(folder?.path ?? "the rips folder").")
        case .encoded(let files, let format, let record):
            encodedFiles = files
            report?.encoding = record
            let took = record?.seconds.map { " in \(Format.duration(seconds: $0))" } ?? ""
            add(
                "Encoded \(files.count) tracks as \(format.rawValue.uppercased())\(took), each checked against the rip."
            )
        case .ripDeleted:
            add("Deleted the rip's WAV files. The rip report is in the album folder.")
        case .ripKept(let folder):
            add("Kept the rip in \(folder.path): not every track is verified and encoded.")
        case .addedToMusic(let count):
            musicResult = "Added \(Format.count(count, "track")) to Music."
            add(musicResult!)
        case .addToMusicFailed(let error):
            musicResult = "Not added to Music: \(error)"
            add(musicResult!)
        }
    }

    /// The encoder writes the tracks in order, so the first one still queued is under way.
    private func startNextEncode() {
        if let next = tracksToRip.sorted().first(where: { encodeStates[$0] == .queued }) {
            encodeStates[next] = .encoding
        }
    }

    private func handle(_ event: RipEvent) {
        switch event {
        case .reading(let track, let pass, let passes, let progress):
            let fraction = progress.sectors > 0 ? Double(progress.sectorsRead) / Double(progress.sectors) : 0
            trackStates[track] = .reading(pass: pass, passes: passes, fraction: fraction)
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
        case .testing(let track, let progress):
            let fraction = progress.sectors > 0 ? Double(progress.sectorsRead) / Double(progress.sectors) : 0
            trackStates[track] = .testing(fraction: fraction)
            onProgress?()
        }
    }
}
