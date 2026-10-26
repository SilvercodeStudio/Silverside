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

    public var description: String {
        switch self {
        case .otherDisc(let folder, let toc): "\(folder.path) holds a rip of another disc (TOC \(toc))."
        case .taken(let first, let second): "Both \(first.path) and \(second.path) hold another disc's rip."
        }
    }
}

/// A rip's folder, claimed for one disc, so that two rips never write into the same folder.
/// The claim is a file that holds the disc's TOC, created atomically, and removed at the end.
public enum RipFolder {
    static let claimFile = ".silverside-rip"
    /// The claim's name before the app was called Silverside, removed with the claim.
    static let oldClaimFile = ".cdrip-rip"

    /// Claims `folder` for the disc. If another disc's rip has it, or it holds another disc's
    /// disc.json, claims "<folder> [<disc ID>]" instead. Returns the folder claimed.
    public static func claim(_ folder: URL, toc: TOC) throws -> URL {
        if try claimIfFree(folder, toc: toc) { return folder }
        let other = folder.deletingLastPathComponent().appending(
            path: "\(folder.lastPathComponent) [\(toc.musicBrainzDiscID)]", directoryHint: .isDirectory)
        guard try claimIfFree(other, toc: toc) else { throw RipFolderError.taken(folder, other) }
        return other
    }

    public static func release(_ folder: URL) {
        for name in [claimFile, oldClaimFile] { try? FileManager.default.removeItem(at: folder.appending(path: name)) }
    }

    private static func claimIfFree(_ folder: URL, toc: TOC) throws -> Bool {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let saved = RipPool.savedTOC(in: folder), saved != toc.ctdbTOCString { return false }
        let path = folder.appending(path: claimFile).path
        let file = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if file >= 0 {
            defer { close(file) }
            _ = toc.ctdbTOCString.withCString { write(file, $0, strlen($0)) }
            return true
        }
        // A claim from an earlier rip of this same disc (one that stopped) can be taken over.
        guard errno == EEXIST, let held = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return held == toc.ctdbTOCString
    }
}
