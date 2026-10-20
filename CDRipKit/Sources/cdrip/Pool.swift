import CDRipKit
import Foundation

/// Earlier rips of a disc, for `rip --pool` and `repair`: their WAV files, and the
/// other values of suspect samples that they kept.
enum Pool {
    /// The versions of a track in `folders` ("Track NN.wav" with the track's length),
    /// and the alternatives that each folder kept for it ("Track NN.suspects").
    static func versions(
        of track: TOC.Track, toc: TOC, in folders: [URL]
    ) -> (versions: [[UInt32]], alternatives: [[Int: [UInt32]]]) {
        let length = toc.sectorRange(of: track).count * CDDA.samplesPerSector
        let name = String(format: "Track %02d.wav", track.number)
        let versions = folders.compactMap { try? WAVFile.read($0.appending(path: name)) }.filter { $0.count == length }
        let alternatives = folders.compactMap {
            try? TrackAudio.readAlternatives(
                from: $0.appending(path: TrackAudio.alternativesFileName(track: track.number)))
        }
        return (versions, alternatives)
    }

    /// How a version of an audio track compares with AccurateRip.
    static func verification(
        of samples: [UInt32], track: TOC.Track, toc: TOC, records: [AccurateRipRecord]
    ) -> AccurateRipVerification {
        let audioTracks = toc.audioTracks
        guard let index = audioTracks.firstIndex(of: track) else { return .notChecked }
        let checksum = AccurateRipAccumulator.checksum(
            of: samples[...], isFirstTrack: index == 0, isLastTrack: index == audioTracks.count - 1)
        let known = records.compactMap { $0.tracks.indices.contains(index) ? $0.tracks[index] : nil }
        return TrackRipper.verification(of: checksum, known: known)
    }

    /// Checks that each folder with a disc.json holds a rip of the disc with `toc`.
    static func check(_ folders: [URL], toc: TOC) throws {
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appending(path: "disc.json")),
                let saved = try? JSONDecoder().decode(SavedTOC.self, from: data)
            else { continue }
            guard saved.toc == toc.ctdbTOCString else {
                throw CommandError("\(folder.path) holds a rip of another disc (TOC \(saved.toc)).")
            }
        }
    }
}

/// The TOC from a rip's disc.json, as `cdrip rip` and the archive write it.
struct SavedTOC: Decodable {
    var toc: String
}
