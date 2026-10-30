import ArgumentParser
import Foundation
import SilversideDarwin
import SilversideKit

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
              silverside rip -d disk14
              silverside rip -d disk14 --encode --format flac
              silverside rip -d disk15 --release 513cbe54-309f-42f6-a883-2b93b3aa776f
              silverside rip -d disk16 --pool "<rip of the same disc from another drive>"
            """)

    @OptionGroup var deviceOptions: DeviceOptions

    @Option(help: "The drive's read offset in samples, for this rip only.")
    var offset: Int?

    @Option(help: "The tracks to rip, such as 1,3-5. Default: all audio tracks. A data track's number saves it.")
    var tracks: String?

    @Option(
        help: """
            For a disc with a data track (an Enhanced CD's extras for a computer): save it as an ISO image, \
            which the encoding copies into the album folder with its files; skip it; or ask (the setting's \
            default), which asks at a terminal, and saves otherwise.
            """)
    var dataTracks: DataTrackChoice?

    @Option(
        name: .shortAndLong,
        help: """
            The folder for the WAV files. Default: named from the MusicBrainz release, such as \
            "Grateful Dead - Cornell 5-8-77 (Disc 1)", or "Silverside <disc ID>" if there is none.
            """)
    var output: String?

    @Option(
        help:
            "The MusicBrainz ID of the release to use. Silverside keeps the choice for the other discs of the release.")
    var release: String?

    @Option(help: "The artwork to save from the Cover Art Archive: front (cover.jpg), all (also Artwork/), or none.")
    var artwork: ArtworkChoice?

    @Flag(inversion: .prefixedNo, help: "After the rip, encode the disc into the library (see silverside encode).")
    var encode: Bool?

    @Flag(
        inversion: .prefixedNo,
        help: "With --encode, keep the rip's WAV files. Without it, a rip that is all verified and encoded is deleted.")
    var keepRip: Bool?

    @Flag(
        inversion: .prefixedNo,
        help: "After the rip, eject the disc if every track is verified. A disc with errors stays in the drive.")
    var eject: Bool?

    @OptionGroup(title: "Encoding, with --encode") var encoding: EncodingOptions

    @Flag(help: "Do not look up AccurateRip, CTDB, MusicBrainz, or AccurateRip's drive offset list.")
    var offline = false

    @Flag(help: "Read each track once, with no re-reads of tracks that do not match AccurateRip.")
    var singlePass = false

    @Flag(help: "Check the rip against CUETools DB, but do not repair it.")
    var noRepair = false

    @Flag(
        inversion: .prefixedNo,
        help: "Test and copy: after each track, read it once more and keep both reads' CRC-32 in the report.")
    var test: Bool?

    @Flag(help: "Do not ask the drive for C2 error flags.")
    var noC2 = false

    @Option(
        help: """
            A folder with an earlier rip of this disc, from any drive. Give it more than once. For each track that \
            is not accurate, an accurate earlier version replaces it; otherwise all versions join the CTDB repair.
            """)
    var pool: [String] = []

    @Flag(
        help: """
            Read every track. Without it, a track that an earlier rip in the folder (a stopped rip leaves its \
            tracks there) or the pool has an accurate copy of, by AccurateRip, is kept and not read again.
            """)
    var readAll = false

    func run() async throws {
        let settings = try Settings.load()
        let bsdName = try deviceOptions.bsdName()
        let drive = try IOKitDrive(bsdName: bsdName)
        guard let device = OpticalDrive.all().first(where: { $0.discBSDName == bsdName }) else {
            throw CommandError("Cannot find the drive that holds \(bsdName).")
        }
        var options = DiscRipOptions(settings: settings)
        options.tracks = try tracks.map(Self.trackNumbers)
        options.readOffset = offset
        options.folder = output.map { URL(filePath: $0, directoryHint: .isDirectory) }
        options.releaseID = release
        if let artwork { options.artwork = artwork }
        options.offline = offline
        options.singlePass = singlePass
        options.repairs = !noRepair
        options.readsC2 = !noC2 && settings.readC2
        if let test { options.testAndCopy = test }
        options.pool = pool.map { URL(filePath: $0, directoryHint: .isDirectory) }
        options.keepsAccurateTracks = !readAll
        if let keepRip { options.keepsRip = keepRip }
        options.addsToMusic = encoding.addsToMusic(settings)
        options.hdcd = encoding.hdcdChoice(settings)
        options.preEmphasis = encoding.preEmphasisChoice(settings)
        options.dts = encoding.dtsChoice(settings)
        options.silentTracks = encoding.silentTrackChoice(settings)
        options.writesEACLog = encoding.eacLog ?? settings.writeEACLog
        options.dataTracks = dataTracks ?? settings.dataTracks

        var rip = DiscRip(
            drive: drive,
            identity: DriveIdentity(vendor: device.vendor, product: device.product, revision: device.revision),
            settings: settings, options: options, profiles: try DriveProfileStore())
        if encode ?? settings.encodeAfterRip { (rip.encoder, rip.library) = encoding.encoder(settings) }
        let printer = RipPrinter()
        rip.events = printer.print
        // Ask when the choice matters, if someone is at the terminal to answer.
        if isatty(STDIN_FILENO) != 0 {
            rip.chooseRelease = ReleaseChoice.askForRelease
            rip.confirmOverwrite = { [printer] existing in
                printer.progress.clear()
                return Self.askToOverwrite(existing)
            }
            rip.chooseHDCD = { [printer] report, format in
                printer.progress.clear()
                return Self.askToDecodeHDCD(report, format: format)
            }
            rip.choosePreEmphasis = { [printer] report, format in
                printer.progress.clear()
                return Self.askToDeEmphasize(report, format: format)
            }
            rip.chooseSilentTracks = { [printer] report in
                printer.progress.clear()
                return Self.askToLeaveOutSilentTracks(report)
            }
            rip.chooseDTS = { [printer] report, format, canDecode in
                printer.progress.clear()
                return Self.askAboutDTS(report, format: format, canDecode: canDecode)
            }
            rip.chooseDataTracks = { [printer] tracks in
                printer.progress.clear()
                return Self.askToSaveDataTracks(tracks)
            }
        }
        // Ctrl-C stops the rip after the read under way; the tracks done so far stay.
        let interrupt = Interrupt(
            stop: rip.stop, message: "Stopping after the read under way. Press Ctrl-C again to stop at once.")
        defer { withExtendedLifetime(interrupt) {} }
        let result: DiscRipResult
        do {
            result = try await rip.run()
            // The history keeps the rip, and its album, even after the files move.
            let history = RipHistory()
            if !result.deletedRip { history.recordReport(at: result.folder.appending(path: "disc.json")) }
            if let folder = result.encodedFiles.first?.deletingLastPathComponent() { history.recordAlbum(in: folder) }
        } catch is CancellationError {
            printer.progress.clear()
            print("Stopped." + (printer.folder.map { " The tracks ripped so far are in \($0.path)." } ?? ""))
            throw ExitCode(130)
        }
        guard eject ?? settings.ejectAfterRip else { return }
        guard result.report.isVerified else {
            print("Kept the disc in the drive: not every track is verified.")
            return
        }
        // The rip is done, so a disc that cannot be ejected does not make it fail.
        do {
            try await DiscEject.eject(bsdName: bsdName)
            print("Ejected the disc.")
        } catch {
            print("Could not eject the disc: \(error)")
        }
    }

    /// The track numbers in a list such as "1,3-5".
    /// Asks at the terminal whether to replace the files of the disc in the library. No is the default.
    static func askToOverwrite(_ existing: [URL]) -> Bool {
        let folder = existing.first?.deletingLastPathComponent().path ?? ""
        print(
            "The library already has \(existing.count == 1 ? "1 file" : "\(existing.count) files") of this disc, in \(folder)."
        )
        print("Replace them? [y/N] ", terminator: "")
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return answer == "y" || answer == "yes"
    }

    /// Asks at the terminal whether to decode a disc's HDCD codes. The default is the
    /// recommendation (`AudioFormat.recommendsHDCDDecode`): decode, except for AIFF and WAV,
    /// whose 24-bit files are half again as large.
    static func askToDecodeHDCD(_ report: RipReport, format: AudioFormat) -> Bool {
        print()
        if let text = report.hdcdText { print(text) }
        let recommended = format.recommendsHDCDDecode
        print(
            !format.isLossless
                ? "Decoding gives the \(format.name) encoder the decoded audio, at no cost in size; \(format.name)"
                    + " files lose the codes, so they cannot be decoded later."
                : "Decoding makes \(format.wideBits)-bit \(format.name) files, \(format.wideBits == 20 ? "a little" : "half again as")"
                    + " larger, as an HDCD player plays the disc. Kept, the files are bit for bit the disc, and can be"
                    + " decoded later.")
        print("Decode the HDCD codes? [\(recommended ? "Y/n" : "y/N")] ", terminator: "")
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return answer.isEmpty ? recommended : answer == "y" || answer == "yes"
    }

    /// Asks at the terminal what to do with a DTS-CD's stream. A decoded copy beside the album
    /// is the default; without ffmpeg, the stream is kept.
    static func askAboutDTS(_ report: RipReport, format: AudioFormat, canDecode: Bool) -> DTSChoice {
        print()
        if let text = report.dtsText { print(text) }
        guard canDecode else {
            print(
                "ffmpeg is not installed, so the files keep the stream. Install it (brew install ffmpeg) to decode it.")
            return .keep
        }
        let decoded = DiscEncoder.surroundFormat(for: format).name
        print(
            "ffmpeg can decode it into \(decoded) files with every channel. d: the album as the disc has it, and a"
                + " decoded copy beside it; o: the decode only; k: the stream only.")
        print("Decode the DTS? [D/o/k] ", terminator: "")
        fflush(stdout)
        switch readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? "" {
        case "o": return .decodeOnly
        case "k": return .keep
        default: return .decode
        }
    }

    /// Asks at the terminal whether to de-emphasize a disc's tracks with pre-emphasis. Yes is the default.
    static func askToDeEmphasize(_ report: RipReport, format: AudioFormat) -> Bool {
        print()
        if let text = report.preEmphasisText { print(text) }
        print(
            "Few players take pre-emphasis out, so those tracks play too bright. De-emphasizing takes it out, as a CD"
                + " player does, into "
                + (format.isLossless ? "\(format.wideBits)-bit \(format.name) files" : "\(format.name) files")
                + " tagged DE_EMPHASIZED=yes. Kept, the files are bit for bit the disc, tagged PRE_EMPHASIS=yes.")
        print("De-emphasize? [Y/n] ", terminator: "")
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return answer.isEmpty || answer == "y" || answer == "yes"
    }

    static func askToLeaveOutSilentTracks(_ report: RipReport) -> Bool {
        print()
        if let text = report.silentTracksText { print(text) }
        print(
            "Left out, they get no files, and the other tracks keep the disc's numbers. A disc image keeps every"
                + " track.")
        print("Leave them out? [Y/n] ", terminator: "")
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return answer.isEmpty || answer == "y" || answer == "yes"
    }

    static func askToSaveDataTracks(_ tracks: [TOC.Track]) -> Bool {
        print()
        print(
            "This disc has a data track (" + tracks.map { "track \($0.number)" }.joined(separator: ", ")
                + ") with extras for a computer. Saved, it becomes an ISO image, and the encoding copies it into"
                + " the album folder with its files.")
        print("Save it? [Y/n] ", terminator: "")
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return answer.isEmpty || answer == "y" || answer == "yes"
    }

    static func trackNumbers(_ list: String) throws -> [Int] {
        var numbers = Set<Int>()
        for part in list.split(separator: ",") {
            let bounds = part.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let first = bounds.first ?? nil, bounds.count <= 2, let last = bounds.last ?? nil, first <= last
            else {
                throw ValidationError("Cannot read the track list \"\(list)\".")
            }
            numbers.formUnion(first...last)
        }
        return numbers.sorted()
    }
}

/// Prints a rip's events, as `silverside rip` shows them. The events come one at a time, from
/// the reading thread, so the state here is used by one thread at a time.
private final class RipPrinter: @unchecked Sendable {
    let progress = ProgressLine()
    var toc: TOC?
    var readOffset = 0
    var checksAccurateRip = false
    /// The rip's folder, once the rip has claimed it.
    var folder: URL?

    func print(_ event: DiscRipEvent) {
        switch event {
        case .disc(let toc):
            self.toc = toc
        case .drive(let drive, let offset, let source):
            readOffset = offset
            Swift.print(SilversideVersion.program)
            Swift.print(
                "Drive: \(drive.name) (firmware \(drive.revision)), read offset \(offset.signedDescription) (\(source))"
            )
        case .lookupFailed(let lookup, let error):
            Swift.print("\(lookup.rawValue): the lookup failed (\(error)). The rip goes on without it.")
        case .lookups(let records, let ctdb):
            checksAccurateRip = (records ?? 0) > 0
            Swift.print(
                "AccurateRip: "
                    + (records.map { $0 == 0 ? "disc not in the database" : "\($0) records" } ?? "not checked"))
            Swift.print(
                "CTDB: "
                    + (ctdb.map {
                        $0.entries == 0
                            ? "disc not in the database"
                            : "\($0.entries) entries, up to \($0.mostSubmissions) submissions"
                    } ?? "not checked"))
        case .release(nil):
            break
        case .release(let lookup?):
            guard let chosen = lookup.chosen, let toc else {
                Swift.print("MusicBrainz: no release has this disc")
                return
            }
            Swift.print(
                "MusicBrainz: " + chosen.summary(for: toc)
                    + (lookup.isExact ? "" : " (a fuzzy match of the TOC; MusicBrainz does not know this disc ID)")
                    + (lookup.otherCount > 0 ? "; \(lookup.otherCount) other releases (see silverside metadata)" : ""))
            if !lookup.isExact {
                Swift.print("  To add the disc ID: \(MusicBrainzRelease.submissionURL(for: toc).absoluteString)")
            }
            if let failure = lookup.detailsFailure {
                Swift.print("  The release's own lookup failed (\(failure)), so the files get no writers or genre.")
            }
        case .releaseLookupFailed(let error):
            Swift.print("MusicBrainz: the lookup failed (\(error))")
        case .folder(let folder, _):
            self.folder = folder
            Swift.print("Folder: \(folder.path)")
            Swift.print()
        case .hiddenTrack(let hidden):
            Swift.print(
                String(format: "Track  0  %@         hidden track before track 1: ", Info.duration(hidden.sectors))
                    + (hidden.readsAgree
                        ? "\(hidden.reads) reads agree (AccurateRip and CTDB do not cover it)"
                        : "NOT verified: \(hidden.reads) reads all differ")
                    + ((hidden.unreadableSectors ?? []).isEmpty
                        ? "" : ", \(hidden.unreadableSectors!.count) sectors unreadable"))
        case .hiddenAreaUnreadable(let sectors, let total):
            Swift.print(
                "Before track 1: \(sectors) of \(total) sectors could not be read, and the rest is silence. "
                    + "This drive may not read before track 1; another drive may find a hidden track there.")
        case .poolFileSkipped(let file):
            Swift.print("Pool: \(file.url.path) was not used: \(file.reason).")
        case .trackStarted(let track, let position, let count):
            progress.label = String(format: "%2d", track.number) + (count > 1 ? " (\(position)/\(count))" : "")
        case .reading(let event):
            progress.show(event)
        case .trackFinished(let report, let summary, let seconds):
            progress.clear()
            Swift.print(
                String(format: "Track %2d  %@  %3d s  ", report.number, Info.duration(report.sectors), seconds)
                    + summary)
        case .controlBits(let summary):
            Swift.print("Control bits: " + summary)
        case .savingDataTrack(let number, let fraction):
            progress.showText(String(format: "Data track %d: %3.0f%%", number, fraction * 100))
        case .dataTrackSaved(let track):
            progress.clear()
            Swift.print(RipReport.dataTrackSummary(track))
        case .dataTrackFailed(let number, let message):
            progress.clear()
            Swift.print("Data track \(number): not saved: \(message)")
        case .checkingCTDB:
            Swift.print()
        case .repairLog(let line):
            Swift.print(line)
        case .repaired(let repair):
            printCTDB(repair)
        case .trackRepaired(let track):
            Swift.print(
                String(format: "  Track %2d  %6d samples repaired", track.number, track.repairedSamples)
                    + track.accurateRipAfterRepair)
        case .ctdbNotChecked:
            Swift.print()
            Swift.print("CTDB: not checked, because it checks the whole disc, and some tracks were not ripped.")
        case .finished(let report, let discOffsets, let profile):
            printSummary(report, discOffsets: discOffsets, profile: profile)
            if let started = report.started {
                let seconds = Int(report.date.timeIntervalSince(started))
                var text = "Took \(RipReport.minutes(seconds))"
                if let ctdb = report.ctdbSeconds { text += ", \(RipReport.minutes(ctdb)) of it the CTDB check" }
                Swift.print(text + ".")
            }
        case .savingArtwork:
            break
        case .artwork(let result):
            ReleaseChoice.printArtwork(result)
        case .artworkFailed(let error):
            Swift.print("Cover: the download failed (\(error))")
        case .encoding:
            Swift.print()
        case .encodedTrack(let line):
            Swift.print("  \(line)")
        case .trackEncoded, .silentTracksLeftOut:
            break
        case .encodingDeclined(let existing):
            let folder = existing.first?.deletingLastPathComponent().path ?? ""
            Swift.print("Did not encode: kept the files in \(folder). The rip is kept, for silverside encode later.")
        case .encoded(let files, let format, let record):
            let took = record?.seconds.map { " in \(RipReport.minutes($0))" } ?? ""
            Swift.print(
                "Encoded \(files.count) tracks as \(format.rawValue.uppercased())\(took), each checked against the rip."
            )
            if let first = files.first { Swift.print("Library: \(first.deletingLastPathComponent().path)") }
        case .ripDeleted:
            Swift.print("Deleted the rip's WAV files (--keep-rip keeps them). The rip report is in the album folder.")
        case .ripKept(let folder):
            Swift.print("Kept the rip in \(folder.path): not every track is verified and encoded.")
        case .addedToMusic(let count):
            Swift.print("Added \(count) tracks to Music.")
        case .addToMusicFailed(let error):
            Swift.print("Music: \(error)")
        }
    }

    private func printCTDB(_ repair: DiscRepairer.Result) {
        let withoutRepairData =
            repair.entriesWithoutRepairData == 0
            ? "" : " \(repair.entriesWithoutRepairData) more entries match, but have no repair data."
        switch repair.outcome {
        case .verified(let entry, let shift):
            Swift.print(
                "CTDB: verified with entry \(entry.id) (\(entry.confidence) submissions)"
                    + (shift == 0 ? "" : " at shift \(shift.signedDescription)") + ".")
        case .repaired(let entry, _, let changed):
            Swift.print(
                "CTDB: repaired \(changed.count) samples with entry \(entry.id) (\(entry.confidence) submissions).")
        case .partlyRepaired(let entry, _, let tracks, let changed):
            Swift.print(
                "CTDB: no entry repairs the whole disc. Repaired \(changed.count) samples in tracks \(tracks)"
                    + " with entry \(entry.id), whose track CRCs then match." + withoutRepairData)
        case .notVerified:
            let matching = repair.trackConfidences.filter { $0 > 0 }.count
            Swift.print(
                "CTDB: no entry verifies or repairs the rip. \(matching) of \(repair.trackConfidences.count) tracks"
                    + " match an entry." + withoutRepairData)
        }
    }

    private func printSummary(_ report: RipReport, discOffsets: Set<Int>, profile: DriveProfile) {
        Swift.print()
        if checksAccurateRip {
            let accurateCount = report.tracks.filter { $0.accurateRip == .accurate }.count
            let otherPressingCount = report.tracks.filter { $0.accurateRip == .otherPressings }.count
            var summary = "\(accurateCount) of \(report.tracks.count) tracks are accurate"
            if otherPressingCount > 0 {
                summary += ", and \(otherPressingCount) more are free of errors (they match other pressings)"
            }
            Swift.print(summary + ".")
            if let note = report.noChecksumNote { Swift.print(note + ".") }
            if !discOffsets.isEmpty {
                let offsets = discOffsets.sorted().map(\.signedDescription).joined(separator: ", ")
                Swift.print("This disc matches AccurateRip at offsets \(offsets).")
                if !discOffsets.contains(readOffset) {
                    Swift.print(
                        "It does not match at the offset used. Either this pressing is not in AccurateRip,"
                            + " or the offset is wrong.")
                }
            }
        }
        if let confirmed = profile.confirmedOffset {
            Swift.print(
                "Rips of \(profile.observations.count) discs confirm this drive's offset: \(confirmed.signedDescription)."
            )
        } else {
            Swift.print("This drive's offset is not yet confirmed by rips of two or more discs.")
        }
        if let hdcd = report.hdcdText { Swift.print(hdcd) }
        if let advice = report.advice {
            Swift.print()
            Swift.print(advice)
        }
    }
}
