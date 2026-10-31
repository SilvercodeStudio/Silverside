import CryptoKit
import Foundation

/// Earlier rips of a disc, for pooling (`rip --pool` and `repair`): their WAV files, and the
/// other values of suspect samples that they kept.
public enum RipPool {
    /// A track file in a pooled folder that could not be used, and why.
    public struct SkippedFile: Equatable, Sendable {
        public var url: URL
        public var reason: String
    }

    /// The versions of a track in `folders` ("Track NN.wav" with the track's length), the
    /// alternatives that each folder kept for it ("Track NN.suspects"), and the track files
    /// that are there but could not be used: not CD audio, or not the track's length.
    public static func versions(
        of track: TOC.Track, toc: TOC, in folders: [URL]
    ) -> (versions: [[UInt32]], alternatives: [[Int: [UInt32]]], skipped: [SkippedFile]) {
        let length = toc.sectorRange(of: track).count * CDDA.samplesPerSector
        let name = String(format: "Track %02d.wav", track.number)
        var versions = [[UInt32]]()
        var skipped = [SkippedFile]()
        for folder in folders {
            let url = folder.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let samples = try WAVFile.read(url)
                if samples.count == length {
                    versions.append(samples)
                } else {
                    skipped.append(.init(url: url, reason: "it has \(samples.count) samples, and the track \(length)"))
                }
            } catch {
                skipped.append(.init(url: url, reason: String(describing: error)))
            }
        }
        let alternatives = folders.compactMap {
            try? TrackAudio.readAlternatives(
                from: $0.appending(path: TrackAudio.alternativesFileName(track: track.number)))
        }
        return (versions, alternatives, skipped)
    }

    /// The report of a rip that was stopped, in its folder: the tracks it finished, written
    /// after each one, so that a later rip can keep them (`accurateCopy`). The finished rip's
    /// disc.json takes its place.
    public static let progressFile = ".silverside-progress.json"

    /// A copy of a track from an earlier rip that AccurateRip says is accurate.
    public struct AccurateCopy: Sendable {
        /// The earlier rip's folder.
        public var folder: URL
        public var samples: [UInt32]
        /// The submissions for the v1 and the v2 checksum.
        public var confidence: [Int]
        /// The track as the earlier rip's report has it, with the same CRC-32: its ISRC,
        /// pregap, index points, and Q control bits, which only a read of the disc gives.
        public var track: RipReport.Track
        /// The samples at the audio's edges that the earlier rip's drive could not read.
        public var paddedEdges: [RipReport.PaddedEdge]
    }

    /// The first "Track NN.wav" in `folders` that AccurateRip says is accurate, checked here
    /// from its samples, and that the folder's report (its disc.json, or a stopped rip's
    /// progress) describes with the same CRC-32: a rip keeps it in place of a read
    /// (`DiscRipOptions.keepsAccurateTracks`). A copy whose drive left more of the audio's
    /// edges as silence than `padding` (this rip's drive would) is not kept: a read gives
    /// more of the track. Nil `padding` does not compare. The folders are read one at a
    /// time, so only one copy of the track is in memory. Nil if none is, or there are no
    /// AccurateRip records.
    public static func accurateCopy(
        of track: TOC.Track, toc: TOC, in folders: [URL], records: [AccurateRipRecord],
        padding: [RipReport.PaddedEdge]?
    ) -> AccurateCopy? {
        guard !records.isEmpty else { return nil }
        let length = toc.sectorRange(of: track).count * CDDA.samplesPerSector
        let name = String(format: "Track %02d.wav", track.number)
        var seen = Set<String>()
        for folder in folders where seen.insert(folder.standardizedFileURL.resolvingSymlinksInPath().path).inserted {
            let reports = ["disc.json", progressFile].compactMap {
                try? RipReport.read(from: folder.appending(path: $0))
            }
            let url = folder.appending(path: name)
            guard !reports.isEmpty, FileManager.default.fileExists(atPath: url.path),
                let samples = try? WAVFile.read(url), samples.count == length,
                case .accurate(let v1, let v2) = verification(of: samples, track: track, toc: toc, records: records)
            else { continue }
            let crc = CRC32.hex(CRC32.checksum(of: samples[...]))
            for report in reports {
                guard let described = report.tracks.first(where: { $0.number == track.number && $0.crc32 == crc })
                else { continue }
                let padded =
                    report.paddedEdges.map { $0.filter { $0.track == track.number } }
                    ?? Self.paddedEdges(of: samples, track: track, toc: toc, readOffset: report.drive.readOffset)
                if let padding,
                    !padded.allSatisfy({ edge in
                        padding.contains {
                            $0.track == edge.track && $0.atEnd == edge.atEnd && $0.samples >= edge.samples
                        }
                    })
                {
                    break
                }
                return AccurateCopy(
                    folder: folder, samples: samples, confidence: [v1, v2], track: described, paddedEdges: padded)
            }
        }
        return nil
    }

    /// The padding of a copy whose report lists none: none at all, or (before 0.9) not known.
    /// It can be no more than its drive's offset allows, and no more than the silence the
    /// copy has at that edge, so an edge whose audio is there (an Enhanced CD's tail read
    /// through the session's lead-out) counts as not padded.
    static func paddedEdges(
        of samples: [UInt32], track: TOC.Track, toc: TOC, readOffset: Int
    ) -> [RipReport.PaddedEdge] {
        DiscRip.paddedEdges(of: toc, readOffset: readOffset, tracks: [track.number]).compactMap { edge in
            let silence = (edge.atEnd ? Array(samples.reversed()) : samples).prefix { $0 == 0 }.count
            let samples = min(edge.samples, silence)
            return samples > 0 ? RipReport.PaddedEdge(track: edge.track, samples: samples, atEnd: edge.atEnd) : nil
        }
    }

    /// How a version of an audio track compares with AccurateRip.
    public static func verification(
        of samples: [UInt32], track: TOC.Track, toc: TOC, records: [AccurateRipRecord]
    ) -> AccurateRipVerification {
        let audioTracks = toc.audioTracks
        guard let index = audioTracks.firstIndex(of: track) else { return .notChecked }
        let checksum = AccurateRipAccumulator.checksum(
            of: samples[...], isFirstTrack: index == 0, isLastTrack: index == audioTracks.count - 1)
        let known = records.entries(forTrackAt: index)
        return TrackRipper.verification(of: checksum, known: known)
    }

    /// Checks that each folder with a disc.json holds a rip of the disc with `toc`.
    public static func check(_ folders: [URL], toc: TOC) throws {
        for folder in folders {
            guard let saved = savedTOC(in: folder) else { continue }
            guard saved == toc.ctdbTOCString else { throw RipFolderError.otherDisc(folder, toc: saved) }
        }
    }

    /// The CTDB TOC in a folder's disc.json (a rip's report or an archive manifest).
    public static func savedTOC(in folder: URL) -> String? {
        struct Saved: Decodable { var toc: String }
        return (try? Data(contentsOf: folder.appending(path: "disc.json"))).flatMap {
            try? JSONDecoder().decode(Saved.self, from: $0).toc
        }
    }
}

public enum RipFolderError: Error, Equatable, CustomStringConvertible {
    /// The folder holds a rip of another disc.
    case otherDisc(URL, toc: String)
    /// Both the folder and its other name hold rips of other discs.
    case taken(URL, URL)
    /// A rip is writing into the folder.
    case inUse(URL)

    public var description: String {
        switch self {
        case .otherDisc(let folder, let toc): "\(folder.path) holds a rip of another disc (TOC \(toc))."
        case .taken(let first, let second): "Both \(first.path) and \(second.path) hold another disc's rip."
        case .inUse(let folder): "A rip is writing into \(folder.path). Try again when it is done."
        }
    }
}

/// A rip's folder, claimed for one disc, so that two rips never write into the same folder.
/// The claim is a file that holds the disc's TOC, created atomically, and removed at the end.
public enum RipFolder {
    static let claimFile = ".silverside-rip"
    private static let claims = Claims()

    private final class Claims: @unchecked Sendable {
        let lock = NSLock()
        var descriptors: [String: Int32] = [:]
    }
    /// The claim's name before the app was called Silverside, removed with the claim.
    static let oldClaimFile = ".cdrip-rip"

    /// Claims `folder` for the disc. If another disc's rip has it, or it holds another disc's
    /// disc.json, claims "<folder> [<disc ID>]" instead. Returns the folder claimed.
    public static func claim(_ folder: URL, toc: TOC) throws -> URL {
        if try claimIfFree(folder, toc: toc) { return folder }
        let other = otherName(of: folder, toc: toc)
        guard try claimIfFree(other, toc: toc) else { throw RipFolderError.taken(folder, other) }
        return other
    }

    /// The folders that `claim` can give a rip of the disc: `folder`, then its other name.
    public static func candidates(_ folder: URL, toc: TOC) -> [URL] {
        [folder, otherName(of: folder, toc: toc)]
    }

    private static func otherName(of folder: URL, toc: TOC) -> URL {
        folder.deletingLastPathComponent().appending(
            path: "\(folder.lastPathComponent) [\(toc.musicBrainzDiscID)]", directoryHint: .isDirectory)
    }

    /// Claims exactly `folder`, for work that must not run beside a rip into it, such as
    /// moving it to the Trash. Throws if a rip has it.
    public static func claimExactly(_ folder: URL, toc: TOC) throws {
        guard try claimIfFree(folder, toc: toc) else { throw RipFolderError.inUse(folder) }
    }

    public static func release(_ folder: URL) {
        let key = claimKey(folder)
        guard let descriptor = claims.lock.withLock({ claims.descriptors.removeValue(forKey: key) }) else { return }
        // Unlink only our own claim, while still holding its lock. Never remove somebody else's claim.
        for name in [claimFile, oldClaimFile] { try? FileManager.default.removeItem(at: folder.appending(path: name)) }
        // rmdir is atomic and refuses to remove a directory containing newly arrived files.
        _ = rmdir(folder.path)
        close(descriptor)
    }

    private static func claimKey(_ folder: URL) -> String {
        folder.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func claimIfFree(_ folder: URL, toc: TOC) throws -> Bool {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let saved = RipPool.savedTOC(in: folder), saved != toc.ctdbTOCString { return false }
        let key = claimKey(folder)
        // Keep lock inodes outside the rip folder and never unlink them. Unlinking a locked
        // file lets a concurrent opener acquire a different inode for the same folder.
        let locks = folder.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
            .appending(path: ".silverside-rip-locks")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = open(locks.appending(path: digest).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        let path = folder.appending(path: claimFile).path
        guard file >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path]) }
        guard flock(file, LOCK_EX | LOCK_NB) == 0 else {
            close(file)
            return false
        }
        var keep = false
        defer { if !keep { close(file) } }
        // Check again under the lock: another rip may have finished since the first check.
        if let saved = RipPool.savedTOC(in: folder), saved != toc.ctdbTOCString { return false }
        // Crashes release the OS lock. An abandoned same-disc claim can therefore be resumed.
        let held = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        guard held.isEmpty || held == toc.ctdbTOCString else { return false }
        try Data(toc.ctdbTOCString.utf8).write(to: URL(filePath: path), options: .atomic)
        claims.lock.withLock { claims.descriptors[key] = file }
        keep = true
        return true
    }
}
