import ArgumentParser
import CDRipDarwin
import CDRipKit
import Foundation

struct Repair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check ripped WAV files against CUETools DB, and repair them with its repair data.")

    @OptionGroup var deviceOptions: DeviceOptions

    @Option(
        help: """
            The disc's CTDB TOC, such as 0:31400:58160:295575. Default: from disc.json in the first input folder, \
            else from the disc in the drive.
            """)
    var toc: String?

    @Option(
        name: .shortAndLong,
        help: """
            A folder with ripped "Track NN.wav" files. Give it more than once to pool several rips of the disc: \
            sectors where they disagree are suspect, and help the repair.
            """)
    var input: [String]

    @Option(
        name: .shortAndLong, help: "The folder for repaired files. Default: the input folder's name with \" repaired\"."
    )
    var output: String?

    @Option(
        help:
            "With the disc in a drive, read each track that does not match AccurateRip until it has this many versions."
    )
    var reads = 3

    @Option(help: "Rounds of re-reads for columns that cannot be repaired, when the disc is in a drive.")
    var rereadRounds = 4

    @Option(help: "The drive's read offset for re-reads. Default: from the drive's profile.")
    var offset: Int?

    func run() async throws {
        guard let firstInput = input.first else { throw ValidationError("Give at least one --input folder.") }
        let firstFolder = URL(filePath: firstInput, directoryHint: .isDirectory).standardizedFileURL
        // The TOC: from --toc, from the rip's disc.json, or from the disc. With the disc
        // in a drive (by --device, or with no other TOC), re-reads are possible.
        let savedTOC =
            (try? JSONDecoder().decode(SavedTOC.self, from: Data(contentsOf: firstFolder.appending(path: "disc.json"))))?
            .toc
        let usesDrive = deviceOptions.device != nil || (self.toc == nil && savedTOC == nil)
        let driveTOC = usesDrive ? try IOKitDrive(bsdName: deviceOptions.bsdName()).readTOC() : nil
        guard let toc = try (self.toc ?? savedTOC).map({ try TOC(ctdbTOCString: $0) }) ?? driveTOC else {
            throw CommandError("The disc's TOC is not known.")
        }
        if let driveTOC, driveTOC.ctdbTOCString != toc.ctdbTOCString {
            throw CommandError("The disc in the drive is not the disc of the rip (TOC \(driveTOC.ctdbTOCString)).")
        }
        let audioTracks = toc.audioTracks
        guard !audioTracks.isEmpty else { throw CommandError("This disc has no audio tracks.") }
        // Earlier re-reads are kept next to the first folder, as "<folder> read 2" and so on.
        let parent = firstFolder.deletingLastPathComponent()
        let readFolders = ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [])
            .filter { $0.hasPrefix(firstFolder.lastPathComponent + " read ") }.sorted()
            .map { parent.appending(path: $0, directoryHint: .isDirectory) }
        let folders = input.map { URL(filePath: $0, directoryHint: .isDirectory) } + readFolders
        // Look everything up first, so that a network problem shows before long re-reads.
        let records = try await AccurateRipRecord.download(for: toc.accurateRipDiscID)
        let entries = try await CTDBEntry.lookup(toc).sorted { $0.confidence > $1.confidence }
        guard !entries.isEmpty else { throw CommandError("This disc is not in CUETools DB.") }

        let reader = usesDrive ? try rereader(toc: toc) : nil

        // Every version of every track, and the disc as the first versions give it, which
        // is enough to find the tracks that match AccurateRip at another pressing's offset.
        var versions = [[[UInt32]]]()
        for track in audioTracks {
            let length = toc.sectorRange(of: track).count * CDDA.samplesPerSector
            let name = String(format: "Track %02d.wav", track.number)
            let found = folders.compactMap { try? WAVFile.read($0.appending(path: name)) }.filter { $0.count == length }
            guard !found.isEmpty else { throw CommandError("No folder has \(name) with the TOC's length.") }
            versions.append(found)
        }
        var trackStarts = [Int]()
        var firstVersions = [UInt32]()
        for trackVersions in versions {
            trackStarts.append(firstVersions.count)
            firstVersions += trackVersions[0]
        }

        // For each track, use a version that matches AccurateRip, at any offset, if there is
        // one. Otherwise the samples where the versions disagree are suspect.
        var tracks = [TrackAudio]()
        for (index, track) in audioTracks.enumerated() {
            let length = versions[index][0].count
            let edges = (isFirst: index == 0, isLast: index == audioTracks.count - 1)
            let known = records.compactMap { $0.tracks.indices.contains(index) ? $0.tracks[index] : nil }
            let accurate = versions[index].first { samples in
                let checksum = AccurateRipAccumulator.checksum(
                    of: samples.span, isFirstTrack: edges.isFirst, isLastTrack: edges.isLast)
                if case .accurate = TrackRipper.verification(of: checksum, known: known) { return true }
                return false
            }
            if let accurate {
                tracks.append(TrackAudio(samples: accurate))
                print(String(format: "Track %2d  accurate in AccurateRip", track.number))
                continue
            }
            if let shift = DiscRepairer.otherPressingShift(
                of: firstVersions, start: trackStarts[index], length: length, edges: edges, known: known)
            {
                tracks.append(TrackAudio(samples: versions[index][0]))
                print(
                    String(format: "Track %2d  free of errors: matches another pressing at ", track.number)
                        + Rip.signed(shift))
                continue
            }
            // With the disc in a drive, read a track that has few versions again, so that
            // the reads can disagree where the disc is damaged.
            var trackVersions = versions[index]
            if let reader, trackVersions.count < reads {
                for _ in trackVersions.count..<reads {
                    reader.flushCache(awayFrom: toc.sectorRange(of: track))
                    let read = try reader.readTrack(track)
                    trackVersions.append(read)
                    // Keep the read, so that a later run can use it.
                    let folder = Self.nextReadFolder(after: firstFolder, track: track)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try WAVFile.write(read, to: folder.appending(path: String(format: "Track %02d.wav", track.number)))
                }
            }
            var audio = TrackAudio(versions: trackVersions)
            // Other values that earlier rips and repairs kept for suspect samples.
            for folder in folders {
                let url = folder.appending(path: TrackAudio.alternativesFileName(track: track.number))
                if let saved = try? TrackAudio.readAlternatives(from: url) { audio.add(saved) }
            }
            tracks.append(audio)
            print(
                String(format: "Track %2d  ", track.number)
                    + "\(trackVersions.count) versions, \(audio.alternatives.count) samples where they disagree")
        }

        print("CTDB: \(entries.count) entries, up to \(entries[0].confidence) submissions")
        var repairer = DiscRepairer(toc: toc, records: records, entries: entries, reader: reader)
        repairer.rereadRounds = rereadRounds
        repairer.log = { print($0) }
        let result = try await repairer.repair(tracks)
        // Keep the alternatives, with the ones that re-reads added, so that a later run can use them.
        let proved: Set<Int>? =
            switch result.outcome {
            case .notVerified: []
            case .partlyRepaired(_, _, let numbers, _): Set(numbers)
            case .verified, .repaired: nil
            }
        if let proved {
            for (index, track) in audioTracks.enumerated()
            where !tracks[index].alternatives.isEmpty && !proved.contains(track.number) {
                var audio = TrackAudio(samples: result.samples(ofTrack: index))
                audio.add(result.alternatives(ofTrack: index))
                try audio.writeAlternatives(
                    to: firstFolder.appending(path: TrackAudio.alternativesFileName(track: track.number)))
            }
        }
        let folder = URL(filePath: firstInput, directoryHint: .isDirectory)
        let withoutRepairData =
            result.entriesWithoutRepairData == 0
            ? "" : "\(result.entriesWithoutRepairData) more entries match the rip's alignment, but have no repair data."
        switch result.outcome {
        case .verified(let entry, let shift):
            print(
                "Verified: the rip matches entry \(entry.id) (\(entry.confidence) submissions)"
                    + (shift == 0 ? "" : " at shift \(Rip.signed(shift))") + ", with no errors.")
        case .repaired:
            try report(result, toc: toc, folder: folder, records: records)
        case .partlyRepaired(_, _, let tracks, _):
            if !withoutRepairData.isEmpty { print(withoutRepairData) }
            print("No entry repairs the whole disc. Keeping the corrections in tracks \(tracks),")
            print("whose CTDB track CRCs then match.")
            try report(result, toc: toc, folder: folder, records: records)
        case .notVerified:
            if !withoutRepairData.isEmpty { print(withoutRepairData) }
            print("Could not verify or repair the rip with any entry.")
        }
    }

    /// An offset-corrected reader for the disc in the drive, with the drive's offset.
    private func rereader(toc: TOC) throws -> AudioReader {
        let bsdName = try deviceOptions.bsdName()
        let drive = try IOKitDrive(bsdName: bsdName)
        var readOffset = offset
        if readOffset == nil, let device = OpticalDrive.all().first(where: { $0.discBSDName == bsdName }) {
            readOffset = try DriveProfileStore().profile(
                vendor: device.vendor, product: device.product, revision: device.revision
            ).offset?.value
        }
        guard let readOffset else { throw CommandError("The drive's read offset is not known. Give it with --offset.") }
        var reader = AudioReader(drive: drive, toc: toc, readOffset: readOffset, canOverread: false)
        reader.unreadableRetries = 3
        return reader
    }

    /// The first "<folder> read N" folder, from N = 2, that has no file for `track`.
    static func nextReadFolder(after folder: URL, track: TOC.Track) -> URL {
        let name = String(format: "Track %02d.wav", track.number)
        for number in 2... {
            let candidate = folder.deletingLastPathComponent().appending(
                path: "\(folder.lastPathComponent) read \(number)", directoryHint: .isDirectory)
            if !FileManager.default.fileExists(atPath: candidate.appending(path: name).path) { return candidate }
        }
        fatalError("Unreachable")
    }

    /// Writes the repaired tracks, and checks them against AccurateRip, which does not depend on CTDB.
    private func report(
        _ result: DiscRepairer.Result, toc: TOC, folder: URL, records: [AccurateRipRecord]
    ) throws {
        let audioTracks = toc.audioTracks
        let destination = URL(
            filePath: output ?? folder.standardizedFileURL.path + " repaired", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let total = audioTracks.indices.reduce(0) { $0 + result.changedSamples(inTrack: $1) }
        print("  Repaired \(total) samples. Files: \(destination.path)")
        for (index, track) in audioTracks.enumerated() {
            let samples = result.samples(ofTrack: index)
            try WAVFile.write(samples, to: destination.appending(path: String(format: "Track %02d.wav", track.number)))
            let checksum = AccurateRipAccumulator.checksum(
                of: samples.span, isFirstTrack: index == 0, isLastTrack: index == audioTracks.count - 1)
            let known = records.compactMap { $0.tracks.indices.contains(index) ? $0.tracks[index] : nil }
            var line = String(
                format: "  Track %2d  %6d samples repaired  ", track.number, result.changedSamples(inTrack: index))
            switch TrackRipper.verification(of: checksum, known: known) {
            case .accurate(let v1, let v2): line += "AccurateRip: accurate (v1 \(v1), v2 \(v2))"
            case .notAccurate: line += "AccurateRip: not accurate"
            case .notChecked: line += "AccurateRip: not in the database"
            }
            print(line)
        }
    }
}

/// The TOC from a rip's disc.json, as `cdrip rip` and the archive write it.
private struct SavedTOC: Decodable {
    var toc: String
}
