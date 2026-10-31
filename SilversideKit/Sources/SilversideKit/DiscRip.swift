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
    /// The track numbers to rip. Nil rips every audio track, and every data track as
    /// `dataTracks` says. A data track's number saves that track.
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
    /// Test and copy: after each track's rip, read it once more and keep that read's CRC-32
    /// in the report beside the copy's.
    public var testAndCopy: Bool
    /// Earlier rips of the disc, from any drive, to pool with this one.
    public var pool: [URL] = []
    /// Keep a track's copy from an earlier rip, in this rip's folder (where a stopped rip
    /// leaves its tracks) or in `pool`, when AccurateRip says it is accurate, and do not read
    /// the track again. False reads every track.
    public var keepsAccurateTracks = true
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
    /// After encoding, add the files to Apple's Music app, if it reads the format.
    public var addsToMusic: Bool
    /// For a disc whose HDCD codes ask for peak extend or a gain adjustment: decode, keep, or
    /// ask `DiscRip.chooseHDCD`.
    public var hdcd: HDCDChoice
    /// For a disc with tracks that have pre-emphasis: de-emphasize them, keep them, or ask
    /// `DiscRip.choosePreEmphasis`.
    public var preEmphasis: PreEmphasisChoice
    /// For a DTS-CD: keep the stream, decode it beside the album or in its place, or ask
    /// `DiscRip.chooseDTS`.
    public var dts: DTSChoice
    /// For a disc with tracks of digital silence: leave them out of the album, keep them, or
    /// ask `DiscRip.chooseSilentTracks`.
    public var silentTracks: SilentTrackChoice
    /// For a disc with data tracks (an Enhanced CD's extras): save them as ISO images beside
    /// the audio, skip them, or ask `DiscRip.chooseDataTracks`.
    public var dataTracks: DataTrackChoice
    /// Write an EAC-style log beside the report ("Rip Report.log", `RipReport.eacStyleLog`).
    public var writesEACLog: Bool
    /// What a look at the disc before the rip found of CD+G graphics (`DiscProbe.cdGraphics`),
    /// for the report. Nil if no one looked.
    public var cdGraphics: Bool?

    public init(settings: Settings) {
        artwork = settings.artwork
        readsC2 = settings.readC2
        testAndCopy = settings.testAndCopy
        keepsRip = settings.keepRipAfterEncoding
        addsToMusic = settings.addToMusic
        hdcd = settings.hdcd
        preEmphasis = settings.preEmphasis
        dts = settings.dts
        silentTracks = settings.silentTracks
        writesEACLog = settings.writeEACLog
        dataTracks = settings.dataTracks
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
    /// Sectors before track 1 could not be read, and what could be read is silence: no
    /// hidden track is kept. Some drives cannot read before track 1.
    case hiddenAreaUnreadable(sectors: Int, of: Int)
    /// A track file in a pooled folder (the `pool` option) could not be used.
    case poolFileSkipped(RipPool.SkippedFile)
    /// A track starts: its position among the tracks to rip, from 1.
    case trackStarted(TOC.Track, position: Int, count: Int)
    /// A read of the track goes on (see `RipEvent`).
    case reading(RipEvent)
    /// A track is done. `summary` says how it compares with AccurateRip, for people to read.
    case trackFinished(RipReport.Track, summary: String, seconds: Int)
    /// The control bits of every track, after the last one: pre-emphasis, digital copy permitted, four-channel audio.
    case controlBits(String)
    /// A data track is being saved as an ISO image: the fraction read.
    case savingDataTrack(number: Int, fraction: Double)
    case dataTrackSaved(RipReport.DataTrack)
    /// A data track could not be saved. The rip goes on without it.
    case dataTrackFailed(number: Int, message: String)
    /// The CTDB check (and repair, if it is needed) starts.
    case checkingCTDB
    /// A line from the CTDB repair, for people to read.
    case repairLog(String)
    /// The CTDB check or repair is done.
    case repaired(DiscRepairer.Result)
    /// A track that the repair changed, written again, with its AccurateRip result after the repair.
    case trackRepaired(RipReport.Track)
    /// The disc is in CTDB, but was not checked: CTDB checks the whole disc, and some tracks were not ripped.
    case ctdbNotChecked
    /// The rip is done: what it found, and what it learned of the drive.
    case finished(RipReport, discOffsets: Set<Int>, profile: DriveProfile)
    /// The rip waits for the artwork download, which ran while the disc was read.
    case savingArtwork
    case artwork(ArtworkResult)
    case artworkFailed(any Error)
    case encoding(AudioFormat)
    /// A line from the encoder, for people to read.
    case encodedTrack(String)
    /// The tracks of digital silence that the encoding leaves out, before the first file.
    case silentTracksLeftOut([Int])
    /// A track's file is written and checked.
    case trackEncoded(number: Int, file: URL)
    /// The library already had these files of the disc, and `confirmOverwrite` kept them:
    /// nothing was encoded, and the rip is kept.
    case encodingDeclined([URL])
    /// The files written, and the record of the encoding that the reports keep (nil if no file was written).
    case encoded([URL], format: AudioFormat, record: RipReport.Encoding?)
    /// After encoding: the rip's files were deleted, or kept because not every track is verified and encoded.
    case ripDeleted
    case ripKept(URL)
    /// The encoded files went into Apple's Music app: how many tracks it added.
    case addedToMusic(Int)
    /// Music did not take the files; the rip and the encoding stand.
    case addToMusicFailed(any Error)
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

/// Rips a disc from start to end, as `silverside rip` and the app do: the lookups, the drive's
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
    /// Asks whether to replace the files of the disc that are already in the library, after
    /// the rip and before the encoder writes any. False keeps them, and the rip is not encoded.
    /// Nil asks nothing: the encoding stops with `EncodingError.exists` unless the encoder overwrites.
    public var confirmOverwrite: (@Sendable (_ existing: [URL]) async -> Bool)?
    /// With `options.hdcd` at `.ask`, for a disc whose HDCD codes ask for peak extend or a gain
    /// adjustment: called after the rip, before encoding. True decodes the codes into 20-bit
    /// files. Nil asks nothing, and the disc is encoded as it is.
    public var chooseHDCD: (@Sendable (_ report: RipReport, _ format: AudioFormat) async -> Bool)?
    /// With `options.preEmphasis` at `.ask`, for a disc with tracks that have pre-emphasis:
    /// called after the rip (and after `chooseHDCD`), before encoding. True de-emphasizes them.
    /// Nil asks nothing, and they are de-emphasized, as advised.
    public var choosePreEmphasis: (@Sendable (_ report: RipReport, _ format: AudioFormat) async -> Bool)?
    /// With `options.dts` at `.ask`, for a DTS-CD: called after the rip, before encoding, with
    /// whether ffmpeg is there to decode it. The answer is not `.ask`. Nil asks nothing, and
    /// the stream is kept.
    public var chooseDTS:
        (@Sendable (_ report: RipReport, _ format: AudioFormat, _ canDecode: Bool) async -> DTSChoice)?
    /// With `options.silentTracks` at `.ask`, for a disc with tracks of digital silence: called
    /// after the rip, before encoding. True leaves them out of the album. Nil asks nothing, and
    /// they are left out.
    public var chooseSilentTracks: (@Sendable (_ report: RipReport) async -> Bool)?
    /// For a disc with data tracks and `DiscRipOptions.dataTracks` ask: true saves them. Asked
    /// as the rip starts, so the answer is not awaited after the audio. Without it, they are saved.
    public var chooseDataTracks: (@Sendable (_ tracks: [TOC.Track]) async -> Bool)?
    public var profiles: DriveProfileStore
    /// The client for every lookup and download. Tests give one with a fake transport.
    public var webClient = WebClient.shared
    /// The covers kept for releases, and the box sets whose discs take their own sleeves.
    public var coverStore = ReleaseCoverStore()
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
        let started = Date()
        let toc = try drive.readTOC()
        guard !toc.audioTracks.isEmpty else { throw DiscRipError.noAudioTracks }
        events(.disc(toc))
        let media = (try? drive.readMediaType()) ?? nil
        let selected = try selectedTracks(of: toc)
        // Whether to save the data tracks: asked now, so that no one waits for the question after the audio.
        let dataTracks = toc.tracks.filter { $0.kind == .data }
        var savesDataTracks = false
        if !dataTracks.isEmpty, options.tracks == nil {
            switch options.dataTracks {
            case .save: savesDataTracks = true
            case .skip: savesDataTracks = false
            case .ask: savesDataTracks = await chooseDataTracks?(dataTracks) ?? true
            }
            try stop.check()
        }

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
                    toc: toc, mcn: mcn, releaseID: options.releaseID, details: true, choose: choose,
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
        // The user's cover: this rip's, else the one kept for the release by an earlier disc or rip.
        var userCover = options.cover
        if userCover == nil, let chosen, !chosen.isManual {
            userCover = coverStore.cover(forReleaseID: chosen.id)
        }
        // A box set whose discs each take their own sleeve from the Cover Art Archive (the
        // user's choice, kept for the release); the cover above stays the set's.
        let position = chosen?.medium(for: toc)?.position
        let sleeveTask: Task<CoverImage?, any Error>? =
            if options.cover == nil, let chosen, !chosen.isManual, let position,
                coverStore.usesDiscSleeves(releaseID: chosen.id)
            {
                Task { [webClient] in
                    try await CoverArtClient(client: webClient).discSleeve(releaseID: chosen.id, disc: position)
                }
            } else {
                nil
            }
        defer { sleeveTask?.cancel() }
        let wanted = options.folder ?? Self.folder(for: named, toc: toc, settings: settings)
        let folder = try RipFolder.claim(wanted, toc: toc)
        defer { RipFolder.release(folder) }
        events(.folder(folder, insteadOf: folder == wanted ? nil : wanted))
        try stop.check()

        // The artwork downloads while the disc is read: the network is idle then, and every
        // image of a release can be a hundred megabytes of scans. The rip waits for it at the end.
        let artworkTask: Task<ArtworkResult, any Error>? =
            if userCover == nil, let chosen, !chosen.isManual {
                Task { [webClient, choice = options.artwork] in
                    try await CoverArtClient(client: webClient).saveArtwork(choice, of: chosen, in: folder)
                }
            } else {
                nil
            }
        defer { artworkTask?.cancel() }

        var reader = AudioReader(drive: drive, toc: toc, readOffset: readOffset, canOverread: false)
        // A sector that cannot be read is silence and suspect, so one bad sector does not stop the rip.
        reader.unreadableRetries = 3
        reader.stop = stop
        // An Enhanced CD's last track can be read to its end where the drive reads the lead-out after it.
        reader.readableLeadOut = try await blocking { AudioReader.sessionLeadOut(of: toc, drive: drive) }
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
        var hiddenAreaUnreadable: Int?
        let flushSectors = profile.cacheFlushSectors
        let hidden =
            selected.first == toc.audioTracks.first
            ? try await blocking({ try HiddenTrackRip.rip(reader: reader, cacheFlushSectors: flushSectors) }) : nil
        if let hidden, hidden.isUnreadable {
            // No track to keep, but the report says what could not be read.
            let sectors = Set(hidden.unreadableSamples.map { $0 / CDDA.samplesPerSector }).count
            hiddenAreaUnreadable = sectors
            events(.hiddenAreaUnreadable(sectors: sectors, of: toc.audioTracks[0].startLBA))
        } else if let hidden {
            try WAVFile.write(hidden.samples, to: folder.appending(path: "Track 00.wav"))
            written.insert("Track 00.wav")
            hiddenTrack = .init(
                file: "Track 00.wav", sectors: toc.audioTracks[0].startLBA, peak: hidden.peak,
                readsAgree: hidden.readsAgree, reads: hidden.reads)
            hiddenTrack?.unreadableSectors = Array(Set(hidden.unreadableSamples.map { $0 / CDDA.samplesPerSector }))
                .sorted()
            hiddenTrack?.cacheFlushIncomplete = hidden.cacheFlushIncomplete ? true : nil
            hiddenTrack?.crc32 = CRC32.hex(CRC32.checksum(of: hidden.samples[...]))
            events(.hiddenTrack(hiddenTrack!))
        }

        var discOffsets = Set<Int>()
        var reports = [RipReport.Track]()
        // Each track's audio, with its suspect samples, for CTDB.
        var trackAudio = [TrackAudio]()
        // The samples at the audio's edges that no drive gave: this drive's for the tracks it
        // read, and the earlier rips' drives' for the tracks kept from them.
        var keptPadding = [RipReport.PaddedEdge]()
        func paddedEdges(of reports: [RipReport.Track]) -> [RipReport.PaddedEdge] {
            let read = Set(reports.filter { $0.keptFrom == nil }.map(\.number))
            return
                (Self.paddedEdges(
                    of: toc, readOffset: readOffset, tracks: read, readableLeadOut: reader.readableLeadOut)
                + keptPadding).sorted { ($0.track, $0.atEnd ? 1 : 0) < ($1.track, $1.atEnd ? 1 : 0) }
        }
        let driveReport = RipReport.Drive(
            vendor: identity.vendor, product: identity.product, revision: identity.revision, readOffset: readOffset,
            offsetSource: source)
        // The tracks finished so far, for a later rip if this one stops (`RipPool.progressFile`).
        let progressFile = folder.appending(path: RipPool.progressFile)
        // An earlier stopped rip's progress: its tracks that this rip has not done yet stay in
        // it, with their padding, so that a rip after this one can still keep them.
        let earlierProgress = try? RipReport.read(from: progressFile)
        // A progress always lists its padding, if only as none.
        let earlierPadding = earlierProgress?.paddedEdges ?? []
        for (position, track) in selected.enumerated() {
            try stop.check()
            events(.trackStarted(track, position: position + 1, count: selected.count))
            let start = ContinuousClock.now
            // The track's rip, with the pooling and the files, on the reading thread.
            let (audio, ripped, ripSummary, copyPadding) = try await blocking { [self] in
                let kept = keptTrack(
                    track, toc: toc, folders: [folder] + options.pool, records: records,
                    padding: Self.paddedEdges(
                        of: toc, readOffset: readOffset, tracks: [track.number],
                        readableLeadOut: reader.readableLeadOut))
                var (samples, summary, audio, report) =
                    try kept?.rip ?? ripTrack(track, toc: toc, ripper: ripper, secure: secure, records: records)
                pool(
                    track, toc: toc, records: records, samples: &samples, audio: &audio, report: &report,
                    summary: &summary)
                let index = toc.audioTracks.firstIndex(of: track)!
                report.recordChecksums(
                    of: samples, isFirstTrack: index == 0, isLastTrack: index == toc.audioTracks.count - 1)
                report.recordDTS(in: samples)
                if options.testAndCopy && report.keptFrom == nil {
                    let test = try testRead(track, toc: toc, reader: reader, cacheFlushSectors: flushSectors)
                    report.testCRC32 = CRC32.hex(test.crc)
                    report.testReadMatches = test.independent ? report.testCRC32 == report.crc32 : nil
                    if !test.independent { report.cacheFlushIncomplete = true }
                    summary +=
                        !test.independent
                        ? ", test read not confirmed: it may have come from the cache"
                        : report.testReadMatches == true ? ", test read matches" : ", TEST READ DIFFERS"
                }
                // Keep the other versions of suspect samples, so that a later repair can use them.
                if !audio.alternatives.isEmpty {
                    try audio.writeAlternatives(
                        to: folder.appending(path: TrackAudio.alternativesFileName(track: track.number)))
                }
                try WAVFile.write(samples, to: folder.appending(path: report.file))
                return (audio, report, summary, kept?.padded)
            }
            var summary = ripSummary
            var report = ripped
            let took = ContinuousClock.now - start
            report.seconds = Int(took.components.seconds)
            // A kept track was not read, so it has no read speed.
            if report.keptFrom == nil {
                report.readSeconds = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
            }
            discOffsets.formUnion(report.matchingOffsets)
            if checksCTDB { trackAudio.append(audio) }
            if !audio.alternatives.isEmpty { written.insert(TrackAudio.alternativesFileName(track: track.number)) }
            written.insert(report.file)
            reports.append(report)
            keptPadding += copyPadding ?? []
            let done = Set(reports.map(\.number))
            var progress = RipReport(
                drive: driveReport, secure: !options.singlePass, toc: toc,
                tracks: (reports + (earlierProgress?.tracks ?? []).filter { !done.contains($0.number) })
                    .sorted { $0.number < $1.number },
                ctdb: .init(status: .notChecked))
            // Never nil: a progress that holds several rips' tracks has no one drive to work it out from.
            progress.paddedEdges = (paddedEdges(of: reports) + earlierPadding.filter { !done.contains($0.track) })
                .sorted { ($0.track, $0.atEnd ? 1 : 0) < ($1.track, $1.atEnd ? 1 : 0) }
            try? progress.write(to: progressFile)
            if let c2 = report.c2Sectors, !c2.isEmpty { summary += ", C2 errors in \(c2.count) sectors" }
            if let unreadable = report.unreadableSectors, !unreadable.isEmpty {
                summary += ", \(unreadable.count) sectors could not be read"
            }
            summary += report.controlBitsSummary
            if report.pregapUnknown == true {
                summary += ", pregap unknown: the Q subchannel near its start could not be read"
            }
            if let indexes = report.indexes {
                summary +=
                    ", index points "
                    + indexes.map { String(format: "%02d", $0.number) + " at " + CueSheet.time($0.sectors) }
                    .joined(separator: ", ")
            }
            if let hdcd = report.hdcd {
                summary += hdcd.changesAudio ? ", HDCD codes (\(hdcd.featuresText))" : ", HDCD codes"
            }
            if report.dts == true { summary += ", a DTS stream" }
            events(.trackFinished(report, summary: summary, seconds: report.seconds ?? 0))
        }

        if let controlBits = RipReport.controlBitsSummary(of: reports) { events(.controlBits(controlBits)) }

        var ctdb = RipReport.CTDBResult(status: entries.isEmpty && checkedCTDB ? .notInDatabase : .notChecked)
        var ctdbSeconds: Int?
        // A stop in the CTDB check keeps the audio's rip, as not checked: Repair can check it later.
        var stoppedInCTDB = false
        if checksCTDB {
            events(.checkingCTDB)
            let ctdbStarted = Date()
            defer { ctdbSeconds = Int(Date().timeIntervalSince(ctdbStarted)) }
            let errorFree = reports.allSatisfy { $0.accurateRip == .accurate || $0.accurateRip == .otherPressings }
            var repairer = DiscRepairer(
                toc: toc, records: records, entries: entries, reader: options.singlePass ? nil : reader)
            repairer.cacheFlushSectors = profile.cacheFlushSectors
            repairer.sectorsReadAlready = Self.sectorsReadAlready(in: reports, toc: toc)
            repairer.stop = stop
            repairer.log = { events(.repairLog($0)) }
            let client = webClient
            repairer.repairData = { try await $0.downloadRepairData(client: client) }
            let repair: DiscRepairer.Result?
            do {
                repair = try await repairer.repair(trackAudio, repairing: !errorFree && options.repairs)
            } catch  where error is CancellationError || stop.isStopped || (error as? URLError)?.code == .cancelled {
                // A stop in the repair data's download comes as URLSession's own error.
                repair = nil
                stoppedInCTDB = true
                events(.repairLog("Stopped. The rip is kept, not checked by CTDB."))
            }
            trackAudio = []
            if let repair {
                ctdb = RipReport.CTDBResult(repair)
                for index in reports.indices { reports[index].ctdbConfidence = repair.trackConfidences[index] }
                events(.repaired(repair))
                try apply(repair, to: &reports, records: records, readOffset: readOffset, folder: folder)
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
        if let cover = userCover {
            do {
                let file = try cover.write(to: folder)
                written.insert(Self.relativePath(of: file, in: folder))
                // Only a cover given for this rip is new; one kept already would end the sleeves.
                if options.cover != nil, let chosen, !chosen.isManual {
                    try? coverStore.remember(cover, forReleaseID: chosen.id)
                }
                events(.artwork(.saved([file])))
            } catch {
                events(.artworkFailed(error))
            }
        } else if let artworkTask {
            events(.savingArtwork)
            do {
                let artwork = try await artworkTask.value
                if case .saved(let files) = artwork {
                    for file in files { written.insert(Self.relativePath(of: file, in: folder)) }
                }
                events(.artwork(artwork))
            } catch {
                events(.artworkFailed(error))
            }
        }
        if let sleeveTask, let position {
            do {
                if let sleeve = try await sleeveTask.value {
                    let file = try CoverFiles.writeDisc(sleeve, position: position, in: folder)
                    written.insert(Self.relativePath(of: file, in: folder))
                    events(.artwork(.saved([file])))
                }
            } catch {
                events(.artworkFailed(error))
            }
        }

        var report = RipReport(drive: driveReport, secure: !options.singlePass, toc: toc, tracks: reports, ctdb: ctdb)
        report.started = Date(timeIntervalSince1970: started.timeIntervalSince1970.rounded(.down))
        report.ctdbSeconds = ctdbSeconds
        report.mcn = mcn
        report.media = media
        report.cdGraphics = options.cdGraphics
        report.hiddenTrack = hiddenTrack
        report.hiddenAreaUnreadableSectors = hiddenAreaUnreadable
        let padded = paddedEdges(of: reports)
        report.paddedEdges = padded.isEmpty ? nil : padded
        report.hdcd = HDCDStatus(reports)
        report.dts = DTSStatus(reports)
        report.cdText = (try? drive.readCDText()).flatMap { $0.flatMap(CDText.init(bytes:)) }
        report.release = chosen
        func writeReport() throws {
            written.formUnion(["disc.json", "Rip Report.md"] + (options.writesEACLog ? ["Rip Report.log"] : []))
            report.files = written.sorted()
            try report.write(to: folder.appending(path: "disc.json"))
            // The rip's report describes its tracks now.
            try? FileManager.default.removeItem(at: progressFile)
            if !edits.isEmpty { try edits.save(inDiscJSONOf: folder) }
            var shown = report
            shown.release = named
            try shown.writeReadable(to: folder.appending(path: "Rip Report.md"), eacLog: options.writesEACLog)
        }
        // The audio's rip is whole before the data tracks are read: a drive can fail there, or
        // stop answering, and the rip is then usable all the same.
        try writeReport()
        if !edits.isEmpty, let chosen, !chosen.isManual, options.edits != nil {
            try ReleaseEditsStore().remember(edits, forReleaseID: chosen.id)
        }
        if stoppedInCTDB { throw CancellationError() }

        // The data tracks, as ISO images: an Enhanced CD's extras for a computer.
        var savedDataTracks = [RipReport.DataTrack]()
        var failures = [RipReport.DataTrackFailure]()
        for track in dataTracks {
            guard options.tracks.map({ $0.contains(track.number) }) ?? savesDataTracks else { continue }
            let file = RipReport.DataTrack.fileName(track: track.number)
            do {
                try stop.check()
                let saved = try await blocking { [self] in
                    try DataTrackReader.read(track, in: toc, drive: drive, to: folder.appending(path: file), stop: stop)
                    {
                        events(.savingDataTrack(number: track.number, fraction: $0))
                    }
                }
                savedDataTracks.append(saved)
                written.insert(file)
                events(.dataTrackSaved(saved))
            } catch is CancellationError {
                // The audio's rip stays as it is; the report says the data track was not saved.
                failures.append(.init(number: track.number, reason: "The rip was stopped."))
                report.dataTrackFailures = failures
                try writeReport()
                throw CancellationError()
            } catch {
                failures.append(.init(number: track.number, reason: "\(error)"))
                events(.dataTrackFailed(number: track.number, message: "\(error)"))
            }
        }
        if !savedDataTracks.isEmpty || !failures.isEmpty {
            report.dataTracks = savedDataTracks.isEmpty ? nil : savedDataTracks
            report.dataTrackFailures = failures.isEmpty ? nil : failures
            try writeReport()
        }
        events(.finished(report, discOffsets: discOffsets, profile: profile))
        var result = DiscRipResult(report: report, folder: folder)

        if var encoder {
            try stop.check()
            let disc = try RippedDisc(folder: folder)
            // Before any question: a rip that is not verified is not encoded, whatever the answers.
            try encoder.checkVerified(disc)
            let library = self.library
            // Before the files in the library are looked at: the answer changes which files there are.
            switch options.silentTracks {
            case .leaveOut: encoder.leavesOutSilentTracks = true
            case .keep: encoder.leavesOutSilentTracks = false
            case .ask:
                encoder.leavesOutSilentTracks = true
                if !report.silentTracks.isEmpty, let chooseSilentTracks {
                    encoder.leavesOutSilentTracks = await chooseSilentTracks(report)
                    try stop.check()
                }
            }
            if !encoder.overwrites, let confirmOverwrite {
                let existing = try encoder.plannedFiles(disc, into: library).filter {
                    FileManager.default.fileExists(atPath: $0.path)
                }
                if !existing.isEmpty {
                    let replaces = await confirmOverwrite(existing)
                    try stop.check()
                    guard replaces else {
                        events(.encodingDeclined(existing))
                        return result
                    }
                    encoder.overwrites = true
                }
            }
            switch options.hdcd {
            case .decode: encoder.decodesHDCD = true
            case .keep: encoder.decodesHDCD = false
            case .ask:
                if report.hdcd == .featuresUsed, let chooseHDCD {
                    encoder.decodesHDCD = await chooseHDCD(report, encoder.format)
                    try stop.check()
                }
            }
            switch options.preEmphasis {
            case .deEmphasize: encoder.deEmphasizes = true
            case .keep: encoder.deEmphasizes = false
            case .ask:
                encoder.deEmphasizes = true
                if report.tracks.contains(where: \.preEmphasis), let choosePreEmphasis {
                    encoder.deEmphasizes = await choosePreEmphasis(report, encoder.format)
                    try stop.check()
                }
            }
            var dts = options.dts
            if report.dts == .stream, dts == .ask {
                dts = await chooseDTS?(report, encoder.format, FFmpeg.program() != nil) ?? .keep
                try stop.check()
            }
            // A lossy format would turn a stream that is not decoded into noise: the rip stays as it is.
            let decodes = (dts == .decode || dts == .decodeOnly) && FFmpeg.program() != nil
            if report.dts == .stream, !decodes, !encoder.format.isLossless {
                events(.encodedTrack(DTSError.lossyStream(encoder.format).description + " The rip is kept."))
                events(.ripKept(folder))
                return result
            }
            events(.encoding(encoder.format))
            encoder.log = { events(.encodedTrack($0)) }
            encoder.trackEncoded = { events(.trackEncoded(number: $0, file: $1)) }
            encoder.tracksLeftOut = { events(.silentTracksLeftOut($0)) }
            let encoded = try await blocking { [encoder, dts] in
                try encoder.encodeWithRecord(disc, into: library, dts: dts)
            }
            let (files, record) = (encoded.files, encoded.encoding)
            result.encodedFiles = files
            // The rip's own report says where its tracks went, for as long as the rip is kept.
            try record?.save(inReportAt: folder.appending(path: "disc.json"))
            events(.encoded(files, format: record?.format ?? encoder.format, record: record))
            if let copy = encoded.copyEncoding {
                events(
                    .encodedTrack(
                        "The decoded copy: \(encoded.copyFiles.count) \(copy.format.name) files in \(copy.folder)"))
            }
            // Music plays a DTS stream as static, so it gets the decode, if there is one.
            let (musicFiles, musicFormat) = encoded.musicFiles
            if options.addsToMusic, let musicFormat, MusicApp.reads(musicFormat), !musicFiles.isEmpty {
                do {
                    events(.addedToMusic(try await blocking { try MusicApp.add(musicFiles) }))
                } catch {
                    events(.addToMusicFailed(error))
                }
            }
            // The WAV files go only if every track is verified and encoded; the report is in the album folder.
            if !options.keepsRip {
                let leftOut = record?.silentTracksLeftOut?.count ?? 0
                if result.encodedFiles.count + leftOut == disc.tracks.count && disc.isFinished {
                    if try disc.deleteRipFiles(albumFolder: record.map { URL(filePath: $0.folder) }) {
                        result.deletedRip = true
                        events(.ripDeleted)
                    } else {
                        events(.ripKept(folder))
                    }
                } else {
                    events(.ripKept(folder))
                }
            }
        }
        return result
    }

    /// The sectors, counted from the first audio track's start, that the secure ripper re-read:
    /// the CTDB repair's re-reads leave them out (`DiscRepairer.sectorsReadAlready`).
    static func sectorsReadAlready(in reports: [RipReport.Track], toc: TOC) -> Set<Int> {
        guard let first = toc.audioTracks.first?.startLBA else { return [] }
        var sectors = Set<Int>()
        for report in reports where report.rereadRounds > 0 {
            guard let track = toc.audioTracks.first(where: { $0.number == report.number }) else { continue }
            sectors.formUnion(report.suspectSectors.map { track.startLBA - first + $0 })
        }
        return sectors
    }

    /// The edges of the disc's audio that a drive without overread cannot read, in the tracks
    /// ripped: with an offset of +N, the last N samples before each end of the audio come from
    /// past it; with -N, the first N after each start. (No drive tested overreads.)
    public static func paddedEdges(
        of toc: TOC, readOffset: Int, tracks: Set<Int>, readableLeadOut: Range<Int>? = nil
    ) -> [RipReport.PaddedEdge] {
        guard readOffset != 0 else { return [] }
        return toc.audioAreas.compactMap { area in
            // The drive reads on into the lead-out after this area.
            if readOffset > 0 && readableLeadOut?.lowerBound == area.upperBound { return nil }
            let sector = readOffset > 0 ? area.upperBound - 1 : area.lowerBound
            guard let track = toc.audioTracks.first(where: { toc.sectorRange(of: $0).contains(sector) }),
                tracks.contains(track.number)
            else { return nil }
            return RipReport.PaddedEdge(track: track.number, samples: abs(readOffset), atEnd: readOffset > 0)
        }
    }

    /// A file's path relative to `folder`, such as "Artwork/back.jpg".
    static func relativePath(of file: URL, in folder: URL) -> String {
        let base = folder.standardizedFileURL.pathComponents
        let path = file.standardizedFileURL.pathComponents
        guard path.starts(with: base) else { return file.lastPathComponent }
        return path.dropFirst(base.count).joined(separator: "/")
    }

    /// The folder that a rip names from the release (with the user's edits applied), in the
    /// settings' rips folder; "Silverside <disc ID>" with no release.
    public static func folder(for named: MusicBrainzRelease?, toc: TOC, settings: Settings) -> URL {
        let name =
            named.map {
                NameTemplate(settings.ripFolderTemplate).name(
                    NameTemplate.values(release: $0, medium: $0.medium(for: toc)))
            } ?? "Silverside \(toc.musicBrainzDiscID)"
        return settings.ripsURL.appending(path: name, directoryHint: .isDirectory)
    }

    private func selectedTracks(of toc: TOC) throws -> [TOC.Track] {
        guard let numbers = options.tracks else { return toc.audioTracks }
        let tracks = toc.audioTracks.filter { numbers.contains($0.number) }
        let missing = numbers.filter { number in !toc.tracks.contains { $0.number == number } }
        guard missing.isEmpty else { throw DiscRipError.noSuchTracks(missing) }
        return tracks
    }

    /// An earlier copy of the track that AccurateRip says is accurate, kept in place of a read
    /// (`keepsAccurateTracks`), from the first of `folders` that has one, with the ISRC,
    /// pregap, index points, and Q control bits from that rip's report, and the samples that
    /// its drive left as silence at the audio's edges. Nil reads the track: no copy, or one
    /// whose drive read less of the edges than this one does.
    private func keptTrack(
        _ track: TOC.Track, toc: TOC, folders: [URL], records: [AccurateRipRecord], padding: [RipReport.PaddedEdge]
    ) -> (
        rip: (samples: [UInt32], summary: String, audio: TrackAudio, report: RipReport.Track),
        padded: [RipReport.PaddedEdge]
    )? {
        guard options.keepsAccurateTracks,
            let copy = RipPool.accurateCopy(of: track, toc: toc, in: folders, records: records, padding: padding)
        else { return nil }
        var report = RipReport.Track(
            number: track.number, file: String(format: "Track %02d.wav", track.number), startLBA: track.startLBA,
            sectors: toc.sectorRange(of: track).count, preEmphasis: track.hasPreEmphasis, accurateRip: .accurate,
            accurateRipConfidence: copy.confidence, fullReads: 0)
        report.tocFlags = RipReport.ControlFlags(track)
        report.accurateRipTop = .top(trackAt: toc.audioTracks.firstIndex(of: track) ?? 0, records: records)
        report.keptFrom = copy.folder.lastPathComponent
        report.isrc = copy.track.isrc
        report.pregapSectors = copy.track.pregapSectors
        report.pregapUnknown = copy.track.pregapUnknown
        report.indexes = copy.track.indexes
        report.recordSubchannel(copy.track.subchannel)
        // In this rip's folder, suspects that an older read left cannot change an accurate track.
        if copy.folder == folders.first {
            try? FileManager.default.removeItem(
                at: copy.folder.appending(path: TrackAudio.alternativesFileName(track: track.number)))
        }
        let summary =
            "accurate (v1 \(copy.confidence[0]), v2 \(copy.confidence[1]) submissions) in the earlier rip in "
            + "\"\(copy.folder.lastPathComponent)\", which is kept: the track was not read again"
        return ((copy.samples, summary, TrackAudio(samples: copy.samples), report), copy.paddedEdges)
    }

    /// Rips one track, once (single pass) or securely, and fills in its report.
    private func ripTrack(
        _ track: TOC.Track, toc: TOC, ripper: TrackRipper, secure: SecureRipper, records: [AccurateRipRecord]
    ) throws -> (samples: [UInt32], summary: String, audio: TrackAudio, report: RipReport.Track) {
        var report = RipReport.Track(
            number: track.number, file: String(format: "Track %02d.wav", track.number), startLBA: track.startLBA,
            sectors: toc.sectorRange(of: track).count, preEmphasis: track.hasPreEmphasis, accurateRip: .notInDatabase)
        report.tocFlags = RipReport.ControlFlags(track)
        report.isrc = try? SubchannelCodes.isrc(of: track, in: toc, drive: drive)
        do {
            report.pregapSectors = try PregapFinder.pregap(of: track, in: toc, drive: drive)
        } catch {
            report.pregapUnknown = true
        }
        // The status when the track matches no checksum: not in AccurateRip, no checksum for it, or not accurate.
        let unmatched = RipReport.AccurateRipStatus.unmatched(
            trackAt: toc.audioTracks.firstIndex(of: track) ?? 0, records: records)
        report.accurateRipTop = .top(trackAt: toc.audioTracks.firstIndex(of: track) ?? 0, records: records)
        if options.singlePass {
            let rip = try ripper.rip(track) { events(.reading($0)) }
            report.matchingOffsets = rip.matchingOffsets
            report.c2Sectors = rip.c2Samples.map { Array(Set($0.map { $0 / CDDA.samplesPerSector })).sorted() }
            report.unreadableSectors = Array(Set(rip.unreadableSamples.map { $0 / CDDA.samplesPerSector })).sorted()
            report.recordSubchannel(rip.subchannel)
            report.recordIndexes(of: track, in: toc, positions: rip.qPositions, drive: drive)
            switch rip.verification {
            case .accurate(let v1, let v2):
                report.accurateRip = .accurate
                report.accurateRipConfidence = [v1, v2]
            case .notAccurate: report.accurateRip = rip.matchingOffsets.isEmpty ? .notAccurate : .otherPressings
            case .notChecked: report.accurateRip = unmatched
            }
            return (rip.samples, rip.summary, TrackAudio(samples: rip.samples), report)
        }
        let rip = try secure.rip(track)
        report.matchingOffsets = rip.matchingOffsets
        report.cacheFlushIncomplete = rip.cacheFlushIncomplete ? true : nil
        report.fullReads = rip.fullReads
        report.rereadRounds = rip.rounds
        report.suspectSectors = rip.suspectSectors
        report.unresolvedSectors = rip.unresolvedSectors
        report.c2Sectors = rip.c2Sectors
        report.shiftedReads = rip.shiftedReads
        report.unreadableSectors = rip.unreadableSectors
        report.recordSubchannel(rip.subchannel)
        report.recordIndexes(of: track, in: toc, positions: rip.qPositions, drive: drive)
        switch rip.status {
        case .accurate(let v1, let v2):
            report.accurateRip = .accurate
            report.accurateRipConfidence = [v1, v2]
        case .matchesOtherPressings: report.accurateRip = .otherPressings
        case .consistent, .consistentButNotAccurate, .suspect: report.accurateRip = unmatched
        }
        // A track free of errors needs no suspects: they could only let a repair change it.
        let errorFree = report.accurateRip == .accurate || report.accurateRip == .otherPressings
        return (rip.samples, rip.summary, errorFree ? TrackAudio(samples: rip.samples) : TrackAudio(rip), report)
    }

    /// Test and copy: one more read of the whole track, after a cache flush so that it comes
    /// from the disc, for a CRC-32 to compare with the copy's. The rip's own reads already
    /// compare sectors; this is the check that EAC's users know.
    private func testRead(_ track: TOC.Track, toc: TOC, reader: AudioReader, cacheFlushSectors: Int) throws -> (
        crc: UInt32, independent: Bool
    ) {
        let sectors = toc.sectorRange(of: track)
        let flushed = try reader.flushCache(awayFrom: sectors, count: cacheFlushSectors)
        let independent =
            flushed || AudioReader.readEvictsItself(sectors: sectors.count, cacheFlushSectors: cacheFlushSectors)
        let start = sectors.lowerBound * CDDA.samplesPerSector
        let readOffset = reader.readOffset
        let events = self.events
        let read = try reader.read(start..<(start + sectors.count * CDDA.samplesPerSector), withC2: false) {
            events(
                .reading(.testing(track: track.number, progress: $0.inTrack(startingAt: start, readOffset: readOffset)))
            )
        }
        return (CRC32.checksum(of: read.samples[...]), independent && read.unreadable.isEmpty)
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
        // The majority of the versions is what CTDB checks, so it is what the WAV file keeps:
        // a repair that changes nothing writes nothing.
        guard audio.samples != samples else { return }
        samples = audio.samples
        if case .accurate(let v1, let v2) = RipPool.verification(
            of: samples, track: track, toc: toc, records: records)
        {
            report.accurateRip = .accurate
            report.accurateRipConfidence = [v1, v2]
            audio = TrackAudio(samples: samples)
            summary += "; the majority of the versions is accurate (v1 \(v1), v2 \(v2) submissions)"
        }
    }

    /// Writes the tracks that the repair changed, and checks them against AccurateRip again,
    /// which does not depend on CTDB. When CTDB verifies the rip as it is, a track that
    /// AccurateRip did not match is checked again too: its re-reads may have ended on the
    /// right values without agreeing, and on a shifted pressing (a CD-R copy) only a check of
    /// the whole disc's audio finds the other pressing's offset.
    private func apply(
        _ repair: DiscRepairer.Result, to reports: inout [RipReport.Track], records: [AccurateRipRecord],
        readOffset: Int, folder: URL
    ) throws {
        switch repair.outcome {
        case .verified:
            for index in reports.indices where reports[index].accurateRip == .notAccurate {
                reports[index].checkAccurateRip(in: repair, trackAt: index, records: records, readOffset: readOffset)
            }
        case .repaired, .partlyRepaired:
            for index in reports.indices where repair.changedSamples(inTrack: index) > 0 {
                let samples = repair.samples(ofTrack: index)
                try WAVFile.write(samples, to: folder.appending(path: reports[index].file))
                reports[index].repairedSamples = repair.changedSamples(inTrack: index)
                reports[index].recordChecksums(
                    of: samples, isFirstTrack: index == 0, isLastTrack: index == reports.count - 1)
                reports[index].recordDTS(in: samples)
                reports[index].checkAccurateRip(in: repair, trackAt: index, records: records, readOffset: readOffset)
                events(.trackRepaired(reports[index]))
            }
        case .notVerified: return
        }
    }
}
