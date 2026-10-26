import CryptoKit
import Foundation

/// The identifiers that AccurateRip uses to find a disc.
public struct AccurateRipDiscID: Hashable, Sendable {
    public let audioTrackCount: Int
    public let id1: UInt32
    public let id2: UInt32
    public let freedbID: UInt32

    /// The name of the disc's database file, such as "dBAR-009-0013f5c6-00949b73-700f6509".
    public var name: String {
        String(format: "dBAR-%03d-%08x-%08x-%08x", audioTrackCount, id1, id2, freedbID)
    }

    public var databaseURL: URL {
        let folders = String(format: "%x/%x/%x/", id1 & 0xF, (id1 >> 4) & 0xF, (id1 >> 8) & 0xF)
        return URL(string: "http://www.accuraterip.com/accuraterip/" + folders + name + ".bin")!
    }
}

extension TOC {
    /// The MusicBrainz disc ID. See https://musicbrainz.org/doc/Disc_ID_Calculation.
    /// The data track of an enhanced CD is not part of the ID.
    public var musicBrainzDiscID: String {
        let idTracks = isEnhanced ? tracks.dropLast() : tracks[...]
        var offsets = [Int](repeating: 0, count: 100)
        offsets[0] = audioLeadOutLBA + CDDA.leadInSectors
        for track in idTracks {
            offsets[track.number] = track.startLBA + CDDA.leadInSectors
        }
        var text = String(format: "%02X%02X", idTracks.first!.number, idTracks.last!.number)
        for offset in offsets {
            text += String(format: "%08X", offset)
        }
        let digest = Data(Insecure.SHA1.hash(data: Data(text.utf8)))
        return digest.base64EncodedString()
            .replacingOccurrences(of: "+", with: ".")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-")
    }

    /// The freedb (CDDB) disc ID. Data tracks are included.
    public var freedbDiscID: UInt32 {
        func digitSum(_ value: Int) -> Int {
            var value = value
            var sum = 0
            while value > 0 {
                sum += value % 10
                value /= 10
            }
            return sum
        }
        func seconds(_ lba: Int) -> Int { (lba + CDDA.leadInSectors) / CDDA.sectorsPerSecond }

        let checksum = tracks.reduce(0) { $0 + digitSum(seconds($1.startLBA)) } % 255
        let length = seconds(leadOutLBA) - seconds(tracks[0].startLBA)
        return UInt32(checksum << 24 | length << 8 | tracks.count)
    }

    /// The AccurateRip disc IDs.
    ///
    /// Verified against the AccurateRip database for audio-only discs, and for an Enhanced CD
    /// (*Mirrorball*, 2026-10-26: the real lead-out, audio tracks only). Not yet verified for a
    /// data track before the audio (mixed mode).
    public var accurateRipDiscID: AccurateRipDiscID {
        var id1: UInt32 = 0
        var id2: UInt32 = 0
        let audio = audioTracks
        for (index, track) in audio.enumerated() {
            let start = UInt32(track.startLBA)
            id1 &+= start
            id2 &+= max(start, 1) &* UInt32(index + 1)
        }
        let leadOut = UInt32(leadOutLBA)
        id1 &+= leadOut
        id2 &+= leadOut &* UInt32(audio.count + 1)
        return AccurateRipDiscID(audioTrackCount: audio.count, id1: id1, id2: id2, freedbID: freedbDiscID)
    }

    /// Makes a TOC from a CTDB TOC string, the reverse of `ctdbTOCString`. A data
    /// track after the audio is put in a second session, as on an enhanced CD.
    public init(ctdbTOCString string: String) throws(TOCError) {
        let parts = string.split(separator: ":").map(String.init)
        guard parts.count >= 2, let leadOut = Int(parts.last!) else { throw .malformed }
        var tracks = [Track]()
        for (index, part) in parts.dropLast().enumerated() {
            let isData = part.hasPrefix("-")
            guard let start = Int(isData ? String(part.dropFirst()) : part) else { throw .malformed }
            let session = isData && index == parts.count - 2 && index > 0 ? 2 : 1
            tracks.append(Track(number: index + 1, startLBA: start, kind: isData ? .data : .audio, session: session))
        }
        try self.init(tracks: tracks, leadOutLBA: leadOut)
    }

    /// The TOC string for CUETools DB lookups: track starts, then the lead-out, separated by colons.
    ///
    /// Verified against CTDB for audio-only discs, and for an Enhanced CD, whose data track has
    /// a "-" prefix (*Mirrorball*, 2026-10-26). Not yet verified for a data track before the audio.
    public var ctdbTOCString: String {
        let starts = tracks.map { ($0.kind == .data ? "-" : "") + String($0.startLBA) }
        return (starts + [String(leadOutLBA)]).joined(separator: ":")
    }
}
