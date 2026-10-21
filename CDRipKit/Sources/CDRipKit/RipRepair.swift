import Foundation

/// What a repair of ripped files is doing, step by step: the CLI prints these, and the app shows them.
public enum RipRepairEvent {
    /// A version of the track matches AccurateRip, and is used.
    case trackAccurate(number: Int)
    /// The track is free of errors: it matches another pressing, `shift` samples away.
    case trackMatchesOtherPressing(number: Int, shift: Int)
    /// The track joins the repair with its versions, which disagree in `suspectSamples` samples.
    case trackPooled(number: Int, versions: Int, suspectSamples: Int)
    case ctdbEntries(count: Int, mostSubmissions: Int)
    /// A line from the CTDB repair, for people to read.
    case repairLog(String)
    /// The repair is done. If it changed the rip, the repaired tracks are written next (`trackWritten`).
    case finished(DiscRepairer.Result)
    /// The folder for the repaired tracks, and the number of samples that the repair changed.
    case writing(URL, repairedSamples: Int)
    /// A repaired track, written, and its AccurateRip result.
    case trackWritten(number: Int, repairedSamples: Int, accurateRip: AccurateRipVerification)
}

public enum RipRepairError: Error, Equatable, CustomStringConvertible {
    case noAudioTracks
    case notInCTDB
    case missingTrack(Int)

    public var description: String {
        switch self {
        case .noAudioTracks: "This disc has no audio tracks."
        case .notInCTDB: "This disc is not in CUETools DB."
        case .missingTrack(let number): String(format: "No folder has Track %02d.wav with the TOC's length.", number)
        }
    }
}

/// Repairs ripped WAV files with CTDB's repair data, as `cdrip repair` does: it pools rips of
/// one disc (from several drives, and earlier re-reads), and with the disc in a drive, reads
/// tracks again so that the reads can disagree where the disc is damaged.
public struct RipRepair {
    public let toc: TOC
    /// The rips to pool. The first is the main one: re-reads and saved suspects go next to it.
    public let folders: [URL]
    /// The folder for the repaired tracks.
    public var output: URL
    /// Reads the disc again. Nil if the disc is not in a drive.
    public var reader: AudioReader?
    public var cacheFlushSectors = 4000
    /// With a reader, read each track that does not match AccurateRip until it has this many versions.
    public var reads = 3
    /// Rounds of re-reads for columns that cannot be repaired.
    public var rereadRounds = 4
    public var events: (RipRepairEvent) -> Void = { _ in }

    /// Pools `folders` with the re-reads that earlier repairs kept next to the first, as
    /// "<folder> read 2" and so on. The repaired tracks go in "<first folder> repaired".
    public init(toc: TOC, folders: [URL]) {
        self.toc = toc
        let first = folders.first?.standardizedFileURL ?? URL.currentDirectory()
        self.folders = folders + Self.readFolders(after: first)
        output = URL(filePath: first.path + " repaired", directoryHint: .isDirectory)
    }

    public func run() async throws -> DiscRepairer.Result {
        let audioTracks = toc.audioTracks
        guard !audioTracks.isEmpty else { throw RipRepairError.noAudioTracks }
        let firstFolder = folders[0].standardizedFileURL
        // Look everything up first, so that a network problem shows before long re-reads.
        let records = try await AccurateRipRecord.download(for: toc.accurateRipDiscID)
        let entries = try await CTDBEntry.lookup(toc).sorted { $0.confidence > $1.confidence }
        guard !entries.isEmpty else { throw RipRepairError.notInCTDB }

        // Every version of every track, and the disc as the first versions give it, which
        // is enough to find the tracks that match AccurateRip at another pressing's offset.
        try RipPool.check(folders, toc: toc)
        var versions = [[[UInt32]]]()
        var saved = [[[Int: [UInt32]]]]()
        for track in audioTracks {
            let pooled = RipPool.versions(of: track, toc: toc, in: folders)
            guard !pooled.versions.isEmpty else { throw RipRepairError.missingTrack(track.number) }
            versions.append(pooled.versions)
            saved.append(pooled.alternatives)
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
                if case .accurate = RipPool.verification(of: samples, track: track, toc: toc, records: records) {
                    return true
                }
                return false
            }
            if let accurate {
                tracks.append(TrackAudio(samples: accurate))
                events(.trackAccurate(number: track.number))
                continue
            }
            if let shift = DiscRepairer.otherPressingShift(
                of: firstVersions, start: trackStarts[index], length: length, edges: edges, known: known)
            {
                tracks.append(TrackAudio(samples: versions[index][0]))
                events(.trackMatchesOtherPressing(number: track.number, shift: shift))
                continue
            }
            // With the disc in a drive, read a track that has few versions again, so that
            // the reads can disagree where the disc is damaged.
            var trackVersions = versions[index]
            if let reader, trackVersions.count < reads {
                for _ in trackVersions.count..<reads {
                    reader.flushCache(awayFrom: toc.sectorRange(of: track), count: cacheFlushSectors)
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
            for alternatives in saved[index] { audio.add(alternatives) }
            tracks.append(audio)
            events(
                .trackPooled(
                    number: track.number, versions: trackVersions.count, suspectSamples: audio.alternatives.count))
        }

        events(.ctdbEntries(count: entries.count, mostSubmissions: entries[0].confidence))
        var repairer = DiscRepairer(toc: toc, records: records, entries: entries, reader: reader)
        repairer.cacheFlushSectors = cacheFlushSectors
        repairer.rereadRounds = rereadRounds
        repairer.log = { events(.repairLog($0)) }
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
        events(.finished(result))
        switch result.outcome {
        case .repaired, .partlyRepaired: try write(result, records: records)
        case .verified, .notVerified: break
        }
        return result
    }

    /// Writes the repaired tracks, and checks them against AccurateRip, which does not depend on CTDB.
    private func write(_ result: DiscRepairer.Result, records: [AccurateRipRecord]) throws {
        let audioTracks = toc.audioTracks
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let total = audioTracks.indices.reduce(0) { $0 + result.changedSamples(inTrack: $1) }
        events(.writing(output, repairedSamples: total))
        for (index, track) in audioTracks.enumerated() {
            let samples = result.samples(ofTrack: index)
            try WAVFile.write(samples, to: output.appending(path: String(format: "Track %02d.wav", track.number)))
            let checksum = AccurateRipAccumulator.checksum(
                of: samples[...], isFirstTrack: index == 0, isLastTrack: index == audioTracks.count - 1)
            let known = records.compactMap { $0.tracks.indices.contains(index) ? $0.tracks[index] : nil }
            events(
                .trackWritten(
                    number: track.number, repairedSamples: result.changedSamples(inTrack: index),
                    accurateRip: TrackRipper.verification(of: checksum, known: known)))
        }
    }

    /// The re-reads that earlier repairs kept next to `folder`: "<folder> read 2" and so on.
    public static func readFolders(after folder: URL) -> [URL] {
        let parent = folder.deletingLastPathComponent()
        return ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [])
            .filter { $0.hasPrefix(folder.lastPathComponent + " read ") }.sorted()
            .map { parent.appending(path: $0, directoryHint: .isDirectory) }
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
}
