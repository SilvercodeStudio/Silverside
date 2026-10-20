import ArgumentParser
import CDRipDarwin
import CDRipKit
import Foundation

struct Rip: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rip audio tracks to WAV files, check them against AccurateRip and CUETools DB, and repair them.")

    @OptionGroup var deviceOptions: DeviceOptions

    @Option(help: "The drive's read offset in samples, for this rip only.")
    var offset: Int?

    @Option(help: "The tracks to rip, such as 1,3-5. Default: all audio tracks.")
    var tracks: String?

    @Option(name: .shortAndLong, help: "The folder for the WAV files. Default: \"CDRip <MusicBrainz disc ID>\".")
    var output: String?

    @Flag(help: "Do not look up AccurateRip or its drive offset list.")
    var offline = false

    @Flag(help: "Read each track once, with no re-reads of tracks that do not match AccurateRip.")
    var singlePass = false

    @Flag(help: "Check the rip against CUETools DB, but do not repair it.")
    var noRepair = false

    func run() async throws {
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

        let folder = URL(filePath: output ?? "CDRip \(toc.musicBrainzDiscID)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        print("Folder: \(folder.path)")
        print()

        let reader = AudioReader(drive: drive, toc: toc, readOffset: readOffset, canOverread: false)
        let ripper = TrackRipper(reader: reader, records: records)
        let secure = SecureRipper(ripper: ripper)
        var discOffsets = Set<Int>()
        var reports = [RipReport.Track]()
        // Each track's audio, with its suspect samples, for CTDB.
        var trackAudio = [TrackAudio]()
        for track in selected {
            let start = ContinuousClock.now
            let samples: [UInt32]
            var result: String
            let file = String(format: "Track %02d.wav", track.number)
            var report = RipReport.Track(
                number: track.number, file: file, startLBA: track.startLBA, sectors: toc.sectorRange(of: track).count,
                preEmphasis: track.hasPreEmphasis, accurateRip: .notInDatabase)
            if singlePass {
                let rip = try ripper.rip(track)
                (samples, result) = (rip.samples, Self.describe(rip))
                discOffsets.formUnion(rip.matchingOffsets)
                report.matchingOffsets = rip.matchingOffsets
                switch rip.verification {
                case .accurate(let v1, let v2):
                    report.accurateRip = .accurate
                    report.accurateRipConfidence = [v1, v2]
                case .notAccurate: report.accurateRip = rip.matchingOffsets.isEmpty ? .notAccurate : .otherPressings
                case .notChecked: break
                }
                if checksCTDB { trackAudio.append(TrackAudio(samples: rip.samples)) }
            } else {
                let rip = try secure.rip(track)
                (samples, result) = (rip.samples, Self.describe(rip))
                discOffsets.formUnion(rip.matchingOffsets)
                report.matchingOffsets = rip.matchingOffsets
                report.fullReads = rip.fullReads
                report.rereadRounds = rip.rounds
                report.suspectSectors = rip.suspectSectors
                report.unresolvedSectors = rip.unresolvedSectors
                switch rip.status {
                case .accurate(let v1, let v2):
                    report.accurateRip = .accurate
                    report.accurateRipConfidence = [v1, v2]
                case .matchesOtherPressings: report.accurateRip = .otherPressings
                case .consistent: break
                case .consistentButNotAccurate, .suspect:
                    report.accurateRip = records.isEmpty ? .notInDatabase : .notAccurate
                }
                if checksCTDB {
                    // A track free of errors needs no suspects: they could only let a repair change it.
                    let errorFree = report.accurateRip == .accurate || report.accurateRip == .otherPressings
                    trackAudio.append(errorFree ? TrackAudio(samples: rip.samples) : TrackAudio(rip))
                }
            }
            try WAVFile.write(samples, to: folder.appending(path: file))
            reports.append(report)
            let seconds = (ContinuousClock.now - start).components.seconds
            if track.hasPreEmphasis { result += ", pre-emphasis" }
            let length = toc.sectorRange(of: track).count
            print(String(format: "Track %2d  %@  %3d s  ", track.number, Info.duration(length), seconds) + result)
        }

        var ctdb = RipReport.CTDBResult(status: entries.isEmpty && !offline ? .notInDatabase : .notChecked)
        if checksCTDB {
            print()
            let errorFree = reports.allSatisfy { $0.accurateRip == .accurate || $0.accurateRip == .otherPressings }
            var repairer = DiscRepairer(toc: toc, records: records, entries: entries, reader: singlePass ? nil : reader)
            repairer.log = { print($0) }
            let repair = try await repairer.repair(trackAudio, repairing: !errorFree && !noRepair)
            trackAudio = []
            ctdb = RipReport.CTDBResult(repair)
            for index in reports.indices { reports[index].ctdbConfidence = repair.trackConfidences[index] }
            try applyRepair(repair, to: &reports, records: records, folder: folder)
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
        let report = RipReport(drive: driveReport, secure: !singlePass, toc: toc, tracks: reports, ctdb: ctdb)
        try report.write(to: folder.appending(path: "disc.json"))
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
                of: samples.span, isFirstTrack: index == 0, isLastTrack: index == reports.count - 1)
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
        switch rip.status {
        case .accurate(let v1, let v2):
            return "accurate (v1 \(v1), v2 \(v2) submissions)" + rereads
        case .matchesOtherPressings(let offsets):
            return
                "free of errors, but matches only other pressings (offsets \(offsets.map(signed).joined(separator: ", ")))"
        case .consistent:
            return "not in AccurateRip; reads agree" + rereads
        case .consistentButNotAccurate:
            return "NOT accurate, but \(rip.fullReads) reads agree: this pressing may not be in AccurateRip,"
                + " or an error reads the same each time"
        case .suspect:
            let most = rip.versionCounts.values.max() ?? 0
            return
                "NOT accurate: \(rip.unresolvedSectors.count) of \(rip.suspectSectors.count) suspect sectors unresolved"
                + rereads + "; up to \(most) versions of a sector"
        }
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
