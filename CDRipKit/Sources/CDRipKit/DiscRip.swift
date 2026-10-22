import Foundation

/// A drive, as its profile names it.
public struct DriveIdentity: Equatable, Sendable {
    public var vendor: String
    public var product: String
    public var revision: String

    public init(vendor: String, product: String, revision: String) {
        self.vendor = vendor
        self.product = product
        self.revision = revision
    }

    public var name: String { "\(vendor) \(product)" }
}

/// What a rip should do, beyond the settings.
public struct DiscRipOptions: Sendable {
    /// The track numbers to rip. Nil rips every audio track.
    public var tracks: [Int]?
    /// The drive's read offset for this rip only. Nil takes it from the drive's profile.
    public var readOffset: Int?
    /// The rip's folder. Nil names it from the release, in the settings' rips folder.
    public var folder: URL?
    /// The MusicBrainz release to use, by ID.
    public var releaseID: String?
    public var artwork: ArtworkChoice
    /// Look up nothing: no AccurateRip, CTDB, MusicBrainz, or drive offset list.
    public var offline = false
    /// Read each track once, with no re-reads.
    public var singlePass = false
    /// Repair the rip with CTDB's repair data. If false, only check it.
    public var repairs = true
    public var readsC2: Bool
    /// Earlier rips of the disc, from any drive, to pool with this one.
    public var pool: [URL] = []
    /// After encoding, keep the rip's WAV files.
    public var keepsRip: Bool
    /// Changes to the release's names, on top of the ones kept for the release (`ReleaseEditsStore`).
    public var edits: MetadataEdits?
    /// A release to use when MusicBrainz has none for the disc (see `MusicBrainzRelease.manual`).
    public var manualRelease: MusicBrainzRelease?
    /// For an offline rip: a release already looked up (the app looks one up when the disc
    /// appears), so that the folder and the report still have the names.
    public var release: MusicBrainzRelease?
    /// A cover the user gave (a JPEG or PNG), saved as the rip's cover in place of the
    /// Cover Art Archive's. It works for a disc MusicBrainz does not know too.
    public var cover: CoverImage?

    public init(settings: Settings) {
        artwork = settings.artwork
        readsC2 = settings.readC2
        keepsRip = settings.keepRipAfterEncoding
    }
}

/// What a rip is doing, step by step: the CLI prints these, and the app shows them. They
/// come from the thread that reads the disc, so the app sends them to its main actor.
public enum DiscRipEvent: Sendable {
    /// The disc's TOC, read before anything else.
    case disc(TOC)
    case drive(DriveIdentity, readOffset: Int, source: String)
    /// A lookup failed, and the rip goes on without it: AccurateRip, CTDB, or the drive
    /// offset list. (A failed MusicBrainz lookup is `releaseLookupFailed`.)
    case lookupFailed(Lookup, any Error)
    /// The number of AccurateRip records, and of CTDB entries with the most submissions.
    /// Nil if the rip is offline, or the lookup failed.
    case lookups(accurateRipRecords: Int?, ctdb: (entries: Int, mostSubmissions: Int)?)

    /// The web services that a rip asks before it reads, named for people.
    public enum Lookup: String, Sendable {
        case driveOffsetList = "AccurateRip's drive offset list"
        case accurateRip = "AccurateRip"
        case ctdb = "CTDB"
    }
    /// The MusicBrainz lookup. Nil if the rip is offline.
    case release(ReleaseLookupResult?)
    case releaseLookupFailed(any Error)
    /// The rip's folder, and the folder it would have used if another disc's rip did not hold it.
    case folder(URL, insteadOf: URL?)
    case hiddenTrack(RipReport.HiddenTrack)
    /// A track file in a pooled folder (the `pool` option) could not be used.
    case poolFileSkipped(RipPool.SkippedFile)
    /// A track starts: its position among the tracks to rip, from 1.
    case trackStarted(TOC.Track, position: Int, count: Int)
    /// A read of the track goes on (see `RipEvent`).
    case reading(RipEvent)
    /// A track is done. `summary` says how it compares with AccurateRip, for people to read.
    case trackFinished(RipReport.Track, summary: String, seconds: Int)
    /// The CTDB check (and repair, if it is needed) starts.
    case checkingCTDB
    /// A line from the CTDB repair, for people to read.
    case repairLog(String)
    /// The CTDB check or repair is done.
    case repaired(DiscRepairer.Result)
    /// A track that the repair changed, written again, and its AccurateRip result after the repair.
    case trackRepaired(number: Int, samples: Int, accurateRip: AccurateRipVerification)
    /// The disc is in CTDB, but was not checked: CTDB checks the whole disc, and some tracks were not ripped.
    case ctdbNotChecked
    /// The rip is done: what it found, and what it learned of the drive.
    case finished(RipReport, discOffsets: Set<Int>, profile: DriveProfile)
    case artwork(ArtworkResult)
    case artworkFailed(any Error)
    case encoding(AudioFormat)
    /// A line from the encoder, for people to read.
    case encodedTrack(String)
    case encoded([URL], format: AudioFormat)
    /// After encoding: the rip's files were deleted, or kept because not every track is verified and encoded.
    case ripDeleted
    case ripKept(URL)
}

public enum DiscRipError: Error, Equatable, CustomStringConvertible {
    case noAudioTracks
    case unknownOffset(String)
    case noSuchTracks([Int])

    public var description: String {
        switch self {
        case .noAudioTracks: "This disc has no audio tracks."
        case .unknownOffset(let drive): "The read offset of \(drive) is not known. Give it with --offset."
        case .noSuchTracks(let numbers):
            "The disc has no audio track \(numbers.map(String.init).joined(separator: ", "))."
        }
    }
}

/// What a rip made.
public struct DiscRipResult: Sendable {
    public var report: RipReport
    public var folder: URL
    /// The encoded files, if the rip encoded.
    public var encodedFiles: [URL] = []
    public var deletedRip = false
}

/// Rips a disc from start to end, as `cdrip rip` and the app do: the lookups, the drive's
/// offset, the release and the rip's folder, the hidden track, a secure rip of each track
/// (with pooling of earlier rips), the CTDB check and repair, the reports, the artwork, and
/// (with an encoder) the encoding.
///
/// `run()` is async, and the reads and the encoding run on a thread of their own (see
/// `blocking(_:)`), so a task that awaits it holds no thread. To stop a rip, cancel that
/// task, or call `stop.stop()` from anywhere: `run()` then throws `CancellationError` after
/// the chunk being read, and the folder keeps the tracks written so far.
public struct DiscRip {
    public let drive: any CDDrive
    public let identity: DriveIdentity
    public var settings: Settings
    public var options: DiscRipOptions
    /// Encodes the disc after the rip, into `library`. Nil does not encode.
    public var encoder: DiscEncoder?
    public var library: URL
    /// Hears each step, on the thread that reads the disc.
    public var events: @Sendable (DiscRipEvent) -> Void = { _ in }
    /// Picks a release when several fit the disc and the ranking cannot settle it. Nil uses the first.
    public var chooseRelease: (@Sendable ([MusicBrainzRelease], TOC) -> MusicBrainzRelease?)?
    public var profiles: DriveProfileStore
    /// The client for every lookup and download. Tests give one with a fake transport.
    public var webClient = WebClient.shared
    /// Stops the rip when set, from any thread.
    public var stop = StopToken()

    public init(
        drive: any CDDrive, identity: DriveIdentity, settings: Settings, options: DiscRipOptions,
        profiles: DriveProfileStore
    ) {
        self.drive = drive
        self.identity = identity
        self.settings = settings
        self.options = options
        self.profiles = profiles
        library = settings.libraryURL
    }

    public func run() async throws -> DiscRipResult {
        let stop = self.stop
        return try await withTaskCancellationHandler {
            try await ripDisc()
        } onCancel: {
            stop.stop()
        }
    }

    private func ripDisc() async throws -> DiscRipResult {
        var profiles = self.profiles
        let toc = try drive.readTOC()
        guard !toc.audioTracks.isEmpty else { throw DiscRipError.noAudioTracks }
        events(.disc(toc))
        let selected = try selectedTracks(of: toc)

        // The drive's profile gives the offset, unless the options do. A drive with no offset
        // at all is looked up in AccurateRip's list; if that fails, the rip cannot go on.
        var profile = profiles.profile(vendor: identity.vendor, product: identity.product, revision: identity.revision)
        if profile.offset == nil && options.readOffset == nil && !options.offline {
            do {
                profile.listedOffset = try await DriveOffsetList.download(client: webClient).entry(
                    vendor: identity.vendor, product: identity.product)?.offset
                try profiles.save(profile)
            } catch {
                events(.lookupFailed(.driveOffsetList, error))
            }
        }
        let readOffset: Int
        let source: String
        if let offset = options.readOffset {
            (readOffset, source) = (offset, "--offset")
        } else if let (value, profileSource) = profile.offset {
            (readOffset, source) = (value, profileSource.description)
        } else {
            throw DiscRipError.unknownOffset(identity.name)
        }
        events(.drive(identity, readOffset: readOffset, source: source))

        // A lookup that fails leaves its check out; the rip goes on, and a repair can check later.
        var records = [AccurateRipRecord]()
        var entries = [CTDBEntry]()
        var checkedAccurateRip = false
        var checkedCTDB = false
        if !options.offline {
            do {
                records = try await AccurateRipRecord.download(for: toc.accurateRipDiscID, client: webClient)
                checkedAccurateRip = true
            } catch {
                events(.lookupFailed(.accurateRip, error))
            }
            do {
                entries = try await CTDBEntry.lookup(toc, client: webClient)
                checkedCTDB = true
            } catch {
                events(.lookupFailed(.ctdb, error))
            }
        }
        events(
            .lookups(
                accurateRipRecords: checkedAccurateRip ? records.count : nil,
                ctdb: checkedCTDB ? (entries.count, entries.map(\.confidence).max() ?? 0) : nil))
        // CTDB checks the whole disc at once.
        let checksCTDB = !entries.isEmpty && selected.count == toc.audioTracks.count
        try RipPool.check(options.pool, toc: toc)
        try stop.check()

        // MusicBrainz names the folder. A failed lookup does not stop the rip.
        let drive = self.drive
        let mcn = try await blocking { try? SubchannelCodes.mcn(in: toc, drive: drive) }
        var chosen: MusicBrainzRelease?
        if options.offline {
            chosen = options.release
            events(.release(nil))
        } else {
            do {
                let choose = chooseRelease.map { choose in { (ranked: [MusicBrainzRelease]) in choose(ranked, toc) } }
                let lookup = try await ReleaseLookup.find(
                    toc: toc, mcn: mcn, releaseID: options.releaseID, choose: choose,
                    client: MusicBrainzClient(client: webClient))
                chosen = lookup.chosen
                events(.release(lookup))
            } catch {
                events(.releaseLookupFailed(error))
            }
        }
        if chosen == nil, let manual = options.manualRelease { chosen = manual }
        // The edits kept for the release, with this rip's on top; the folder is named after them.
        var edits = options.edits ?? MetadataEdits()
        if let chosen, !chosen.isManual, let kept = ReleaseEditsStore().edits(forReleaseID: chosen.id) {
            edits = kept.merged(with: edits)
        }
        let named = chosen.map { edits.applied(to: $0, toc: toc) }
        let name =
            named.map {
                NameTemplate(settings.ripFolderTemplate).name(
                    NameTemplate.values(release: $0, medium: $0.medium(for: toc)))
            } ?? "Silverside \(toc.musicBrainzDiscID)"
        let wanted =
            options.folder ?? settings.ripsURL.appending(path: name, directoryHint: .isDirectory)
        let folder = try RipFolder.claim(wanted, toc: toc)
        defer { RipFolder.release(folder) }
        events(.folder(folder, insteadOf: folder == wanted ? nil : wanted))
        try stop.check()

        var reader = AudioReader(drive: drive, toc: toc, readOffset: readOffset, canOverread: false)
        // A sector that cannot be read is silence and suspect, so one bad sector does not stop the rip.
        reader.unreadableRetries = 3
        reader.stop = stop
        var ripper = TrackRipper(reader: reader, records: records)
        ripper.readsC2 = options.readsC2
        var secure = SecureRipper(ripper: ripper)
        secure.cacheFlushSectors = profile.cacheFlushSectors
        let events = self.events
        secure.progress = { events(.reading($0)) }

        // The files written in the folder, for the report: a later deletion takes only these.
        var written = Set<String>()

        // Audio before track 1, if the disc hides a track there; silence is not kept.
        var hiddenTrack: RipReport.HiddenTrack?
        let flushSectors = profile.cacheFlushSectors
        if selected.first == toc.audioTracks.first,
            let hidden = try await blocking({ try HiddenTrackRip.rip(reader: reader, cacheFlushSectors: flushSectors) })
        {
            try WAVFile.write(hidden.samples, to: folder.appending(path: "Track 00.wav"))
            written.insert("Track 00.wav")
            hiddenTrack = .init(
                file: "Track 00.wav", sectors: toc.audioTracks[0].startLBA, peak: hidden.peak,
                readsAgree: hidden.readsAgree, reads: hidden.reads)
            events(.hiddenTrack(hiddenTrack!))
        }

        var discOffsets = Set<Int>()
        var reports = [RipReport.Track]()
        // Each track's audio, with its suspect samples, for CTDB.
        var trackAudio = [TrackAudio]()
        for (position, track) in selected.enumerated() {
            try stop.check()
            events(.trackStarted(track, position: position + 1, count: selected.count))
            let start = ContinuousClock.now
            // The track's rip, with the pooling and the files, on the reading thread.
            let (audio, report, ripSummary) = try await blocking { [self] in
                var (samples, summary, audio, report) = try ripTrack(
                    track, toc: toc, ripper: ripper, secure: secure, records: records)
                pool(
                    track, toc: toc, records: records, samples: &samples, audio: &audio, report: &report,
                    summary: &summary)
                // Keep the other versions of suspect samples, so that a later repair can use them.
                if !audio.alternatives.isEmpty {
                    try audio.writeAlternatives(
                        to: folder.appending(path: TrackAudio.alternativesFileName(track: track.number)))
                }
                try WAVFile.write(samples, to: folder.appending(path: report.file))
                return (audio, report, summary)
            }
            var summary = ripSummary
            discOffsets.formUnion(report.matchingOffsets)
            if checksCTDB { trackAudio.append(audio) }
            if !audio.alternatives.isEmpty { written.insert(TrackAudio.alternativesFileName(track: track.number)) }
            written.insert(report.file)
            reports.append(report)
            if let c2 = report.c2Sectors, !c2.isEmpty { summary += ", C2 errors in \(c2.count) sectors" }
            if let unreadable = report.unreadableSectors, !unreadable.isEmpty {
                summary += ", \(unreadable.count) sectors could not be read"
            }
            if track.hasPreEmphasis { summary += ", pre-emphasis" }
            events(
                .trackFinished(
                    report, summary: summary, seconds: Int((ContinuousClock.now - start).components.seconds)))
        }

        var ctdb = RipReport.CTDBResult(status: entries.isEmpty && checkedCTDB ? .notInDatabase : .notChecked)
        if checksCTDB {
            events(.checkingCTDB)
            let errorFree = reports.allSatisfy { $0.accurateRip == .accurate || $0.accurateRip == .otherPressings }
            var repairer = DiscRepairer(
                toc: toc, records: records, entries: entries, reader: options.singlePass ? nil : reader)
            repairer.cacheFlushSectors = profile.cacheFlushSectors
            repairer.stop = stop
            repairer.log = { events(.repairLog($0)) }
            let client = webClient
            repairer.repairData = { try await $0.downloadRepairData(client: client) }
            let repair = try await repairer.repair(trackAudio, repairing: !errorFree && options.repairs)
            trackAudio = []
            ctdb = RipReport.CTDBResult(repair)
            for index in reports.indices { reports[index].ctdbConfidence = repair.trackConfidences[index] }
            events(.repaired(repair))
            try apply(repair, to: &reports, records: records, folder: folder)
            // Keep the alternatives, with the ones that re-reads added, for tracks that are not yet right.
            for (index, report) in reports.enumerated() {
                let name = TrackAudio.alternativesFileName(track: report.number)
                let url = folder.appending(path: name)
                var audio = TrackAudio(samples: repair.samples(ofTrack: index))
                audio.add(repair.alternatives(ofTrack: index))
                let isRight = report.accurateRip == .accurate || report.accurateRip == .otherPressings
                if isRight || audio.alternatives.isEmpty || ctdb.status == .repaired {
                    try? FileManager.default.removeItem(at: url)
                    written.remove(name)
                } else {
                    try audio.writeAlternatives(to: url)
                    written.insert(name)
                }
            }
        } else if !entries.isEmpty {
            events(.ctdbNotChecked)
        }

        if !records.isEmpty && !discOffsets.isEmpty {
            profile.record(
                disc: toc.accurateRipDiscID.name, offsets: Array(discOffsets),
                title: named.map { "\($0.artist) - \($0.title)" })
            try profiles.save(profile)
        }

        // The artwork comes before the report, which lists its files.
        if let cover = options.cover {
            do {
                let file = try cover.write(to: folder)
                written.insert(Self.relativePath(of: file, in: folder))
                events(.artwork(.saved([file])))
            } catch {
                events(.artworkFailed(error))
            }
        } else if let chosen, !chosen.isManual {
            do {
                let artwork = try await CoverArtClient(client: webClient).saveArtwork(
                    options.artwork, of: chosen, in: folder)
                if case .saved(let files) = artwork {
                    for file in files { written.insert(Self.relativePath(of: file, in: folder)) }
                }
                events(.artwork(artwork))
            } catch {
                events(.artworkFailed(error))
            }
        }

        let driveReport = RipReport.Drive(
            vendor: identity.vendor, product: identity.product, revision: identity.revision, readOffset: readOffset,
            offsetSource: source)
        var report = RipReport(drive: driveReport, secure: !options.singlePass, toc: toc, tracks: reports, ctdb: ctdb)
        report.mcn = mcn
        report.hiddenTrack = hiddenTrack
        report.cdText = (try? drive.readCDText()).flatMap { $0.flatMap(CDText.init(bytes:)) }
        report.release = chosen
        written.formUnion(["disc.json", "Rip Report.md"])
        report.files = written.sorted()
        try report.write(to: folder.appending(path: "disc.json"))
        if !edits.isEmpty {
            try edits.save(inDiscJSONOf: folder)
            if let chosen, !chosen.isManual, options.edits != nil {
                try ReleaseEditsStore().remember(edits, forReleaseID: chosen.id)
            }
        }
        var shown = report
        shown.release = named
        try Data(shown.markdown.utf8).write(to: folder.appending(path: "Rip Report.md"))
        events(.finished(report, discOffsets: discOffsets, profile: profile))
        var result = DiscRipResult(report: report, folder: folder)

        if var encoder {
            try stop.check()
            events(.encoding(encoder.format))
            encoder.log = { events(.encodedTrack($0)) }
            let disc = try RippedDisc(folder: folder)
            let library = self.library
            result.encodedFiles = try await blocking { [encoder] in try encoder.encode(disc, into: library) }
            events(.encoded(result.encodedFiles, format: encoder.format))
            // The WAV files go only if every track is verified and encoded; the report is in the album folder.
            if !options.keepsRip {
                if result.encodedFiles.count == disc.tracks.count && disc.tracks.allSatisfy(\.isVerified) {
                    try disc.deleteRipFiles()
                    result.deletedRip = true
                    events(.ripDeleted)
                } else {
                    events(.ripKept(folder))
                }
            }
        }
        return result
    }

    /// A file's path relative to `folder`, such as "Artwork/back.jpg".
    static func relativePath(of file: URL, in folder: URL) -> String {
        let base = folder.standardizedFileURL.pathComponents
        let path = file.standardizedFileURL.pathComponents
        guard path.starts(with: base) else { return file.lastPathComponent }
        return path.dropFirst(base.count).joined(separator: "/")
    }

    private func selectedTracks(of toc: TOC) throws -> [TOC.Track] {
        guard let numbers = options.tracks else { return toc.audioTracks }
        let tracks = toc.audioTracks.filter { numbers.contains($0.number) }
        let missing = numbers.filter { number in !tracks.contains { $0.number == number } }
        guard missing.isEmpty else { throw DiscRipError.noSuchTracks(missing) }
        return tracks
    }

    /// Rips one track, once (single pass) or securely, and fills in its report.
    private func ripTrack(
        _ track: TOC.Track, toc: TOC, ripper: TrackRipper, secure: SecureRipper, records: [AccurateRipRecord]
    ) throws -> (samples: [UInt32], summary: String, audio: TrackAudio, report: RipReport.Track) {
        var report = RipReport.Track(
            number: track.number, file: String(format: "Track %02d.wav", track.number), startLBA: track.startLBA,
            sectors: toc.sectorRange(of: track).count, preEmphasis: track.hasPreEmphasis, accurateRip: .notInDatabase)
        report.isrc = try? SubchannelCodes.isrc(of: track, in: toc, drive: drive)
        report.pregapSectors = try? PregapFinder.pregap(of: track, in: toc, drive: drive)
        if options.singlePass {
            let rip = try ripper.rip(track) { events(.reading($0)) }
            report.matchingOffsets = rip.matchingOffsets
            report.c2Sectors = rip.c2Samples.map { Array(Set($0.map { $0 / CDDA.samplesPerSector })).sorted() }
            report.unreadableSectors = Array(Set(rip.unreadableSamples.map { $0 / CDDA.samplesPerSector })).sorted()
            switch rip.verification {
            case .accurate(let v1, let v2):
                report.accurateRip = .accurate
                report.accurateRipConfidence = [v1, v2]
            case .notAccurate: report.accurateRip = rip.matchingOffsets.isEmpty ? .notAccurate : .otherPressings
            case .notChecked: break
            }
            return (rip.samples, rip.summary, TrackAudio(samples: rip.samples), report)
        }
        let rip = try secure.rip(track)
        report.matchingOffsets = rip.matchingOffsets
        report.fullReads = rip.fullReads
        report.rereadRounds = rip.rounds
        report.suspectSectors = rip.suspectSectors
        report.unresolvedSectors = rip.unresolvedSectors
        report.c2Sectors = rip.c2Sectors
        report.shiftedReads = rip.shiftedReads
        report.unreadableSectors = rip.unreadableSectors
        switch rip.status {
        case .accurate(let v1, let v2):
            report.accurateRip = .accurate
            report.accurateRipConfidence = [v1, v2]
        case .matchesOtherPressings: report.accurateRip = .otherPressings
        case .consistent: break
        case .consistentButNotAccurate, .suspect:
            report.accurateRip = records.isEmpty ? .notInDatabase : .notAccurate
        }
        // A track free of errors needs no suspects: they could only let a repair change it.
        let errorFree = report.accurateRip == .accurate || report.accurateRip == .otherPressings
        return (rip.samples, rip.summary, errorFree ? TrackAudio(samples: rip.samples) : TrackAudio(rip), report)
    }

    /// Earlier rips (the `pool` option): an accurate version replaces this read; otherwise
    /// every version joins the repair.
    private func pool(
        _ track: TOC.Track, toc: TOC, records: [AccurateRipRecord], samples: inout [UInt32], audio: inout TrackAudio,
        report: inout RipReport.Track, summary: inout String
    ) {
        guard !options.pool.isEmpty, report.accurateRip != .accurate, report.accurateRip != .otherPressings else {
            return
        }
        let pooled = RipPool.versions(of: track, toc: toc, in: options.pool)
        for file in pooled.skipped { events(.poolFileSkipped(file)) }
        for version in pooled.versions {
            if case .accurate(let v1, let v2) = RipPool.verification(
                of: version, track: track, toc: toc, records: records)
            {
                samples = version
                audio = TrackAudio(samples: version)
                report.accurateRip = .accurate
                report.accurateRipConfidence = [v1, v2]
                summary += "; an earlier rip is accurate (v1 \(v1), v2 \(v2) submissions) and is used"
                return
            }
        }
        guard !pooled.versions.isEmpty else { return }
        let own = audio
        audio = TrackAudio(versions: [samples] + pooled.versions)
        audio.add(own.alternatives)
        for alternatives in pooled.alternatives { audio.add(alternatives) }
        summary += "; pooled with \(pooled.versions.count) earlier versions"
    }

    /// Writes the tracks that the repair changed, and checks them against AccurateRip again,
    /// which does not depend on CTDB.
    private func apply(
        _ repair: DiscRepairer.Result, to reports: inout [RipReport.Track], records: [AccurateRipRecord], folder: URL
    ) throws {
        switch repair.outcome {
        case .repaired, .partlyRepaired: break
        case .verified, .notVerified: return
        }
        for index in reports.indices where repair.changedSamples(inTrack: index) > 0 {
            let samples = repair.samples(ofTrack: index)
            try WAVFile.write(samples, to: folder.appending(path: reports[index].file))
            reports[index].repairedSamples = repair.changedSamples(inTrack: index)
            let checksum = AccurateRipAccumulator.checksum(
                of: samples[...], isFirstTrack: index == 0, isLastTrack: index == reports.count - 1)
            let known = records.compactMap { $0.tracks.indices.contains(index) ? $0.tracks[index] : nil }
            let verification = TrackRipper.verification(of: checksum, known: known)
            switch verification {
            case .accurate(let v1, let v2):
                reports[index].accurateRip = .accurate
                reports[index].accurateRipConfidence = [v1, v2]
            case .notAccurate:
                reports[index].accurateRip = .notAccurate
            case .notChecked:
                break
            }
            events(
                .trackRepaired(
                    number: reports[index].number, samples: reports[index].repairedSamples, accurateRip: verification))
        }
    }
}
