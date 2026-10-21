import ArgumentParser
import CDRipDarwin
import CDRipKit
import Foundation

struct Rip: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rip audio tracks to WAV files, check them against AccurateRip and CUETools DB, and repair them.",
        discussion: """
            Each track is read once. A track that does not match AccurateRip is read again, and the sectors that \
            read differently (or have C2 errors) are re-read until their data matches or the re-reads give up. \
            Then the whole disc is checked against CTDB and, if it has errors, repaired with CTDB's repair data. \
            The folder gets the WAV files, disc.json (the rip report, the TOC, and the release), and cover.jpg. \
            In a terminal, a status line shows each read, with C2 errors and sectors that cannot be read.

            Examples:
              cdrip rip -d disk14
              cdrip rip -d disk14 --encode --format flac
              cdrip rip -d disk15 --release 513cbe54-309f-42f6-a883-2b93b3aa776f
              cdrip rip -d disk16 --pool "<rip of the same disc from another drive>"
            """)

    @OptionGroup var deviceOptions: DeviceOptions

    @Option(help: "The drive's read offset in samples, for this rip only.")
    var offset: Int?

    @Option(help: "The tracks to rip, such as 1,3-5. Default: all audio tracks.")
    var tracks: String?

    @Option(
        name: .shortAndLong,
        help: """
            The folder for the WAV files. Default: named from the MusicBrainz release, such as \
            "Grateful Dead - Cornell 5-8-77 (Disc 1)", or "CDRip <disc ID>" if there is none.
            """)
    var output: String?

    @Option(
        help: "The MusicBrainz ID of the release to use. CDRip keeps the choice for the other discs of the release.")
    var release: String?

    @Option(help: "The artwork to save from the Cover Art Archive: front (cover.jpg), all (also Artwork/), or none.")
    var artwork: ArtworkChoice?

    @Flag(inversion: .prefixedNo, help: "After the rip, encode the disc into the library (see cdrip encode).")
    var encode: Bool?

    @Flag(
        inversion: .prefixedNo,
        help: "With --encode, keep the rip's WAV files. Without it, a rip that is all verified and encoded is deleted.")
    var keepRip: Bool?

    @OptionGroup(title: "Encoding, with --encode") var encoding: EncodingOptions

    @Flag(help: "Do not look up AccurateRip, CTDB, MusicBrainz, or AccurateRip's drive offset list.")
    var offline = false

    @Flag(help: "Read each track once, with no re-reads of tracks that do not match AccurateRip.")
    var singlePass = false

    @Flag(help: "Check the rip against CUETools DB, but do not repair it.")
    var noRepair = false

    @Flag(help: "Do not ask the drive for C2 error flags.")
    var noC2 = false

    @Option(
        help: """
            A folder with an earlier rip of this disc, from any drive. Give it more than once. For each track that \
            is not accurate, an accurate earlier version replaces it; otherwise all versions join the CTDB repair.
            """)
    var pool: [String] = []

    func run() async throws {
        let settings = try Settings.load()
        let bsdName = try deviceOptions.bsdName()
        let drive = try IOKitDrive(bsdName: bsdName)
        let toc = try drive.readTOC()
        guard !toc.audioTracks.isEmpty else { throw CommandError("This disc has no audio tracks.") }
        let selected = try Self.tracks(tracks, of: toc)

        // The drive's profile gives the offset, unless --offset does.
        guard let device = OpticalDrive.all().first(where: { $0.discBSDName == bsdName }) else {
            throw CommandError("Cannot find the drive that holds \(bsdName).")
        }
        let driveName = "\(device.vendor) \(device.product)"
        var store = try DriveProfileStore()
        var profile = store.profile(vendor: device.vendor, product: device.product, revision: device.revision)
        if profile.listedOffset == nil && !offline {
            profile.listedOffset = try await DriveOffsetList.download().entry(
                vendor: device.vendor, product: device.product)?.offset
            try store.save(profile)
        }
        let readOffset: Int
        let source: String
        if let offset {
            (readOffset, source) = (offset, "--offset")
        } else if let (value, profileSource) = profile.offset {
            (readOffset, source) = (value, Self.describe(profileSource))
        } else {
            throw CommandError("The read offset of \(driveName) is not known. Give it with --offset.")
        }
        print("Drive: \(driveName) (firmware \(device.revision)), read offset \(Self.signed(readOffset)) (\(source))")

        let records = offline ? [] : try await AccurateRipRecord.download(for: toc.accurateRipDiscID)
        print(
            "AccurateRip: "
                + (offline
                    ? "not checked (--offline)"
                    : records.isEmpty ? "disc not in the database" : "\(records.count) records"))
        let entries = offline ? [] : try await CTDBEntry.lookup(toc)
        print(
            "CTDB: "
                + (offline
                    ? "not checked (--offline)"
                    : entries.isEmpty
                        ? "disc not in the database"
                        : "\(entries.count) entries, up to \(entries.map(\.confidence).max()!) submissions"))
        // CTDB checks the whole disc at once.
        let checksCTDB = !entries.isEmpty && selected.count == toc.audioTracks.count

        let poolFolders = pool.map { URL(filePath: $0, directoryHint: .isDirectory) }
        try Pool.check(poolFolders, toc: toc)
        // MusicBrainz names the folder. A failed lookup does not stop the rip.
        let mcn = try? SubchannelCodes.mcn(in: toc, drive: drive)
        var chosen: MusicBrainzRelease?
        if !offline {
            do {
                // Ask when the choice matters, if someone is at the terminal to answer.
                let choice = try await ReleaseChoice.find(
                    toc: toc, mcn: mcn, releaseID: release, ask: isatty(STDIN_FILENO) != 0)
                chosen = choice.chosen
                if let chosen {
                    let others = choice.ranked.count - (choice.ranked.contains { $0.id == chosen.id } ? 1 : 0)
                    print(
                        "MusicBrainz: " + ReleaseChoice.describe(chosen, toc: toc)
                            + (choice.isExact
                                ? "" : " (a fuzzy match of the TOC; MusicBrainz does not know this disc ID)")
                            + (others > 0 ? "; \(others) other releases (see cdrip metadata)" : ""))
                    if !choice.isExact {
                        print("  To add the disc ID: \(MusicBrainzRelease.submissionURL(for: toc).absoluteString)")
                    }
                } else {
                    print("MusicBrainz: no release has this disc")
                }
            } catch {
                print("MusicBrainz: the lookup failed (\(error))")
            }
        }
        let defaultName =
            chosen.map {
                NameTemplate(settings.ripFolderTemplate).name(
                    NameTemplate.values(release: $0, medium: $0.medium(for: toc)))
            } ?? "CDRip \(toc.musicBrainzDiscID)"
        let ripsFolder = settings.rips.isEmpty ? URL.currentDirectory() : Settings.expand(settings.rips)
        try FileManager.default.createDirectory(at: ripsFolder, withIntermediateDirectories: true)
        let folder = try RipFolder.claim(
            output.map { URL(filePath: $0, directoryHint: .isDirectory) }
                ?? ripsFolder.appending(path: defaultName, directoryHint: .isDirectory), toc: toc)
        defer { RipFolder.release(folder) }
        print("Folder: \(folder.path)")
        print()

        var reader = AudioReader(drive: drive, toc: toc, readOffset: readOffset, canOverread: false)
        // A sector that cannot be read is silence and suspect, so one bad sector does not stop the rip.
        reader.unreadableRetries = 3
        var ripper = TrackRipper(reader: reader, records: records)
        ripper.readsC2 = !noC2 && settings.readC2
        var secure = SecureRipper(ripper: ripper)
        secure.cacheFlushSectors = profile.cacheFlushSectors
        var discOffsets = Set<Int>()
        var reports = [RipReport.Track]()
        // Each track's audio, with its suspect samples, for CTDB.
        var trackAudio = [TrackAudio]()
        let progress = ProgressLine()
        secure.progress = progress.show
        for (position, track) in selected.enumerated() {
            progress.label =
                String(format: "%2d", track.number) + (selected.count > 1 ? " (\(position + 1)/\(selected.count))" : "")
            let start = ContinuousClock.now
            var samples: [UInt32]
            var result: String
            var audio: TrackAudio
            let file = String(format: "Track %02d.wav", track.number)
            var report = RipReport.Track(
                number: track.number, file: file, startLBA: track.startLBA, sectors: toc.sectorRange(of: track).count,
                preEmphasis: track.hasPreEmphasis, accurateRip: .notInDatabase)
            report.isrc = try? SubchannelCodes.isrc(of: track, in: toc, drive: drive)
            if singlePass {
                let rip = try ripper.rip(track, progress: progress.show)
                (samples, result) = (rip.samples, Self.describe(rip))
                discOffsets.formUnion(rip.matchingOffsets)
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
                audio = TrackAudio(samples: rip.samples)
            } else {
                let rip = try secure.rip(track)
                (samples, result) = (rip.samples, Self.describe(rip))
                discOffsets.formUnion(rip.matchingOffsets)
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
                audio = errorFree ? TrackAudio(samples: rip.samples) : TrackAudio(rip)
            }
            // Earlier rips (--pool): an accurate version replaces this read; otherwise every
            // version joins the repair.
            if !poolFolders.isEmpty && report.accurateRip != .accurate && report.accurateRip != .otherPressings {
                let pooled = Pool.versions(of: track, toc: toc, in: poolFolders)
                var replacement: (samples: [UInt32], v1: Int, v2: Int)?
                for version in pooled.versions where replacement == nil {
                    if case .accurate(let v1, let v2) = Pool.verification(
                        of: version, track: track, toc: toc, records: records)
                    {
                        replacement = (version, v1, v2)
                    }
                }
                if let replacement {
                    samples = replacement.samples
                    audio = TrackAudio(samples: replacement.samples)
                    report.accurateRip = .accurate
                    report.accurateRipConfidence = [replacement.v1, replacement.v2]
                    result +=
                        "; an earlier rip is accurate (v1 \(replacement.v1), v2 \(replacement.v2) submissions) and is used"
                } else if !pooled.versions.isEmpty {
                    let own = audio
                    audio = TrackAudio(versions: [samples] + pooled.versions)
                    audio.add(own.alternatives)
                    for alternatives in pooled.alternatives { audio.add(alternatives) }
                    result += "; pooled with \(pooled.versions.count) earlier versions"
                }
            }
            if checksCTDB { trackAudio.append(audio) }
            // Keep the other versions of suspect samples, so that a later repair can use them.
            if !audio.alternatives.isEmpty {
                try audio.writeAlternatives(
                    to: folder.appending(path: TrackAudio.alternativesFileName(track: track.number)))
            }
            try WAVFile.write(samples, to: folder.appending(path: file))
            reports.append(report)
            let seconds = (ContinuousClock.now - start).components.seconds
            if let c2 = report.c2Sectors, !c2.isEmpty { result += ", C2 errors in \(c2.count) sectors" }
            if let unreadable = report.unreadableSectors, !unreadable.isEmpty {
                result += ", \(unreadable.count) sectors could not be read"
            }
            if track.hasPreEmphasis { result += ", pre-emphasis" }
            let length = toc.sectorRange(of: track).count
            progress.clear()
            print(String(format: "Track %2d  %@  %3d s  ", track.number, Info.duration(length), seconds) + result)
        }

        var ctdb = RipReport.CTDBResult(status: entries.isEmpty && !offline ? .notInDatabase : .notChecked)
        if checksCTDB {
            print()
            let errorFree = reports.allSatisfy { $0.accurateRip == .accurate || $0.accurateRip == .otherPressings }
            var repairer = DiscRepairer(toc: toc, records: records, entries: entries, reader: singlePass ? nil : reader)
            repairer.cacheFlushSectors = profile.cacheFlushSectors
            repairer.log = { print($0) }
            let repair = try await repairer.repair(trackAudio, repairing: !errorFree && !noRepair)
            trackAudio = []
            ctdb = RipReport.CTDBResult(repair)
            for index in reports.indices { reports[index].ctdbConfidence = repair.trackConfidences[index] }
            try applyRepair(repair, to: &reports, records: records, folder: folder)
            // Keep the alternatives, with the ones that re-reads added, for tracks that are not yet right.
            for (index, report) in reports.enumerated() {
                let url = folder.appending(path: TrackAudio.alternativesFileName(track: report.number))
                var audio = TrackAudio(samples: repair.samples(ofTrack: index))
                audio.add(repair.alternatives(ofTrack: index))
                if report.accurateRip == .accurate || report.accurateRip == .otherPressings
                    || audio.alternatives.isEmpty
                    || ctdb.status == .repaired
                {
                    try? FileManager.default.removeItem(at: url)
                } else {
                    try audio.writeAlternatives(to: url)
                }
            }
        } else if !entries.isEmpty {
            print()
            print("CTDB: not checked, because it checks the whole disc, and some tracks were not ripped.")
        }

        print()
        if !records.isEmpty {
            let accurateCount = reports.filter { $0.accurateRip == .accurate }.count
            let otherPressingCount = reports.filter { $0.accurateRip == .otherPressings }.count
            var summary = "\(accurateCount) of \(selected.count) tracks are accurate"
            if otherPressingCount > 0 {
                summary += ", and \(otherPressingCount) more are free of errors (they match other pressings)"
            }
            print(summary + ".")
            if !discOffsets.isEmpty {
                profile.record(disc: toc.accurateRipDiscID.name, offsets: Array(discOffsets))
                try store.save(profile)
                print(
                    "This disc matches AccurateRip at offsets \(discOffsets.sorted().map(Self.signed).joined(separator: ", "))."
                )
            }
            if !discOffsets.isEmpty && !discOffsets.contains(readOffset) {
                print(
                    "It does not match at the offset used. Either this pressing is not in AccurateRip, or the offset is wrong."
                )
            }
        }
        if let confirmed = profile.confirmedOffset {
            print("Rips of \(profile.observations.count) discs confirm this drive's offset: \(Self.signed(confirmed)).")
        } else {
            print("This drive's offset is not yet confirmed by rips of two or more discs.")
        }

        let driveReport = RipReport.Drive(
            vendor: device.vendor, product: device.product, revision: device.revision, readOffset: readOffset,
            offsetSource: source)
        var report = RipReport(drive: driveReport, secure: !singlePass, toc: toc, tracks: reports, ctdb: ctdb)
        report.mcn = mcn
        report.release = chosen
        try report.write(to: folder.appending(path: "disc.json"))
        if let chosen {
            do {
                try await ReleaseChoice.saveArtwork(artwork ?? settings.artwork, of: chosen, in: folder)
            } catch {
                print("Cover: the download failed (\(error))")
            }
        }
        if encode ?? settings.encodeAfterRip {
            print()
            var (encoder, libraryURL) = encoding.encoder(settings)
            encoder.log = { print("  \($0)") }
            let disc = try RippedDisc(folder: folder)
            let files = try encoder.encode(disc, into: libraryURL)
            print(
                "Encoded \(files.count) tracks as \(encoder.format.rawValue.uppercased()), each checked against the rip."
            )
            if let first = files.first { print("Library: \(first.deletingLastPathComponent().path)") }
            // The WAV files go only if every track is verified and encoded; the report is in the album folder.
            if !(keepRip ?? settings.keepRipAfterEncoding) && files.count == disc.tracks.count
                && disc.tracks.allSatisfy(\.isVerified)
            {
                try disc.deleteRipFiles()
                print("Deleted the rip's WAV files (--keep-rip keeps them). The rip report is in the album folder.")
            } else if !(keepRip ?? settings.keepRipAfterEncoding) {
                print("Kept the rip in \(folder.path): not every track is verified and encoded.")
            }
        }
    }

    /// Prints the CTDB result. Writes the tracks that the repair changed, and checks them
    /// against AccurateRip again, which does not depend on CTDB.
    private func applyRepair(
        _ repair: DiscRepairer.Result, to reports: inout [RipReport.Track], records: [AccurateRipRecord], folder: URL
    ) throws {
        let withoutRepairData =
            repair.entriesWithoutRepairData == 0
            ? "" : " \(repair.entriesWithoutRepairData) more entries match, but have no repair data."
        switch repair.outcome {
        case .verified(let entry, let shift):
            print(
                "CTDB: verified with entry \(entry.id) (\(entry.confidence) submissions)"
                    + (shift == 0 ? "" : " at shift \(Self.signed(shift))") + ".")
            return
        case .repaired(let entry, _, let changed):
            print("CTDB: repaired \(changed.count) samples with entry \(entry.id) (\(entry.confidence) submissions).")
        case .partlyRepaired(let entry, _, let tracks, let changed):
            print(
                "CTDB: no entry repairs the whole disc. Repaired \(changed.count) samples in tracks \(tracks)"
                    + " with entry \(entry.id), whose track CRCs then match." + withoutRepairData)
        case .notVerified:
            let matching = repair.trackConfidences.filter { $0 > 0 }.count
            print(
                "CTDB: no entry verifies or repairs the rip. \(matching) of \(reports.count) tracks match an entry."
                    + withoutRepairData)
            return
        }
        for index in reports.indices where repair.changedSamples(inTrack: index) > 0 {
            let samples = repair.samples(ofTrack: index)
            try WAVFile.write(samples, to: folder.appending(path: reports[index].file))
            reports[index].repairedSamples = repair.changedSamples(inTrack: index)
            let checksum = AccurateRipAccumulator.checksum(
                of: samples[...], isFirstTrack: index == 0, isLastTrack: index == reports.count - 1)
            let known = records.compactMap { $0.tracks.indices.contains(index) ? $0.tracks[index] : nil }
            var line = String(
                format: "  Track %2d  %6d samples repaired", reports[index].number, reports[index].repairedSamples)
            switch TrackRipper.verification(of: checksum, known: known) {
            case .accurate(let v1, let v2):
                reports[index].accurateRip = .accurate
                reports[index].accurateRipConfidence = [v1, v2]
                line += "  AccurateRip: accurate (v1 \(v1), v2 \(v2) submissions)"
            case .notAccurate:
                reports[index].accurateRip = .notAccurate
                line += "  AccurateRip: NOT accurate"
            case .notChecked:
                break
            }
            print(line)
        }
    }

    /// The audio tracks that a list such as "1,3-5" names, or all audio tracks.
    static func tracks(_ list: String?, of toc: TOC) throws -> [TOC.Track] {
        guard let list else { return toc.audioTracks }
        var numbers = Set<Int>()
        for part in list.split(separator: ",") {
            let bounds = part.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let first = bounds.first ?? nil, bounds.count <= 2, let last = bounds.last ?? nil, first <= last
            else {
                throw ValidationError("Cannot read the track list \"\(list)\".")
            }
            numbers.formUnion(first...last)
        }
        let tracks = toc.audioTracks.filter { numbers.contains($0.number) }
        guard tracks.count == numbers.count else {
            throw ValidationError("The disc has no audio track for some of \(list).")
        }
        return tracks
    }

    static func describe(_ rip: TrackRip) -> String {
        switch rip.verification {
        case .accurate(let v1, let v2):
            return "accurate (v1 \(v1), v2 \(v2) submissions)"
        case .notAccurate:
            let others = rip.matchingOffsets.map(signed).joined(separator: ", ")
            return "NOT accurate" + (others.isEmpty ? "" : " (matches at offsets \(others))")
        case .notChecked:
            return "not checked"
        }
    }

    static func describe(_ rip: SecureTrackRip) -> String {
        var rereads = ""
        if rip.fullReads > 1 || rip.rounds > 0 {
            rereads = ", after \(rip.fullReads) reads of the track"
            if !rip.suspectSectors.isEmpty {
                rereads += " and \(rip.rounds) re-reads of \(rip.suspectSectors.count) sectors"
            }
        }
        var shifted = ""
        if !rip.shiftedReads.isEmpty {
            let shifts = rip.shiftedReads.map { signed($0) }.joined(separator: ", ")
            shifted =
                rip.firstReadWasShifted
                ? "; the first read lost its place (\(shifts) samples) and was replaced"
                : "; \(rip.shiftedReads.count) reads lost their place (\(shifts) samples) and were left out"
        }
        let text: String
        switch rip.status {
        case .accurate(let v1, let v2):
            text = "accurate (v1 \(v1), v2 \(v2) submissions)" + rereads
        case .matchesOtherPressings(let offsets):
            text =
                "free of errors, but matches only other pressings (offsets \(offsets.map(signed).joined(separator: ", ")))"
        case .consistent:
            text = "not in AccurateRip; reads agree" + rereads
        case .consistentButNotAccurate:
            text =
                "NOT accurate, but \(rip.fullReads) reads agree: this pressing may not be in AccurateRip,"
                + " or an error reads the same each time"
        case .suspect:
            let most = rip.versionCounts.values.max() ?? 0
            text =
                "NOT accurate: \(rip.unresolvedSectors.count) of \(rip.suspectSectors.count) suspect sectors unresolved"
                + rereads + "; up to \(most) versions of a sector"
        }
        return text + shifted
    }

    static func describe(_ source: DriveProfile.OffsetSource) -> String {
        switch source {
        case .manual: "set by hand"
        case .confirmed: "confirmed by rips"
        case .accurateRipList: "from AccurateRip's drive list"
        }
    }

    static func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }
}
