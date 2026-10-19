/// The table of contents of a disc. All positions are LBAs, where LBA 0 is the
/// start of the program area (MSF 00:02:00).
public struct TOC: Equatable, Sendable {
    public struct Track: Equatable, Sendable {
        public enum Kind: Sendable {
            case audio
            case data
        }

        public var number: Int
        public var startLBA: Int
        public var kind: Kind
        public var session: Int
        public var hasPreEmphasis: Bool
        public var isCopyPermitted: Bool

        public init(
            number: Int,
            startLBA: Int,
            kind: Kind = .audio,
            session: Int = 1,
            hasPreEmphasis: Bool = false,
            isCopyPermitted: Bool = false
        ) {
            self.number = number
            self.startLBA = startLBA
            self.kind = kind
            self.session = session
            self.hasPreEmphasis = hasPreEmphasis
            self.isCopyPermitted = isCopyPermitted
        }
    }

    public let tracks: [Track]

    /// The start of the last lead-out on the disc.
    public let leadOutLBA: Int

    public init(tracks: [Track], leadOutLBA: Int) throws(TOCError) {
        guard let first = tracks.first, let last = tracks.last else { throw .noTracks }
        guard tracks.count <= 99, first.number >= 1 else { throw .invalidTrackNumbers }
        guard first.startLBA >= 0 else { throw .invalidStart(track: first.number) }
        for (previous, track) in zip(tracks, tracks.dropFirst()) {
            guard track.number == previous.number + 1 else { throw .invalidTrackNumbers }
            guard track.startLBA > previous.startLBA, track.session >= previous.session else {
                throw .invalidStart(track: track.number)
            }
        }
        guard leadOutLBA > last.startLBA else { throw .invalidLeadOut }
        self.tracks = tracks
        self.leadOutLBA = leadOutLBA
    }

    /// Makes an audio-only TOC from track start LBAs. Tracks are numbered from 1.
    public init(audioTrackStarts: [Int], leadOutLBA: Int) throws(TOCError) {
        let tracks = audioTrackStarts.enumerated().map { Track(number: $0.offset + 1, startLBA: $0.element) }
        try self.init(tracks: tracks, leadOutLBA: leadOutLBA)
    }

    public var audioTracks: [Track] { tracks.filter { $0.kind == .audio } }

    /// True if the last track is data in a later session (Blue Book "CD Extra").
    public var isEnhanced: Bool {
        guard tracks.count >= 2, let last = tracks.last else { return false }
        return last.kind == .data && last.session > tracks[tracks.count - 2].session
    }

    /// The end of the audio session. On an enhanced CD, this is before the session gap.
    public var audioLeadOutLBA: Int {
        isEnhanced ? tracks[tracks.count - 1].startLBA - CDDA.sessionGapSectors : leadOutLBA
    }

    public func track(_ number: Int) -> Track? {
        let index = number - tracks[0].number
        return tracks.indices.contains(index) ? tracks[index] : nil
    }

    /// The sectors of a track, up to the start of the next track. The next track's
    /// pregap (index 00) is in this range, as AccurateRip expects.
    public func sectorRange(of track: Track) -> Range<Int> {
        let index = track.number - tracks[0].number
        precondition(tracks.indices.contains(index) && tracks[index] == track, "Track is not in this TOC")
        let end: Int
        if index == tracks.count - 1 {
            end = leadOutLBA
        } else if isEnhanced && index == tracks.count - 2 {
            end = audioLeadOutLBA
        } else {
            end = tracks[index + 1].startLBA
        }
        return track.startLBA..<end
    }
}

extension TOC {
    /// Parses a full TOC (MMC READ TOC format 0010b) with binary MSF addresses, as
    /// `DKIOCCDREADTOC` returns it for `kCDTOCFormatTOC`.
    public init(fullTOC bytes: [UInt8]) throws(TOCError) {
        guard bytes.count >= 4 else { throw .malformed }
        let end = min(bytes.count, 2 + (Int(bytes[0]) << 8 | Int(bytes[1])))
        var tracks = [Track]()
        var leadOut: (session: Int, lba: Int)?
        // Each 11-byte descriptor: session, ADR and control, TNO, point, MSF, zero, PMSF.
        for start in stride(from: 4, to: end - 10, by: 11) {
            let session = Int(bytes[start])
            let adr = bytes[start + 1] >> 4
            let control = bytes[start + 1] & 0x0F
            let point = bytes[start + 3]
            let minute = Int(bytes[start + 8])
            let second = Int(bytes[start + 9])
            let frame = Int(bytes[start + 10])
            let lba = (minute * 60 + second) * CDDA.sectorsPerSecond + frame - CDDA.leadInSectors
            guard adr == 1 else { continue }
            switch point {
            case 1...99:
                let isData = control & 0x04 != 0
                tracks.append(
                    Track(
                        number: Int(point), startLBA: lba, kind: isData ? .data : .audio, session: session,
                        hasPreEmphasis: !isData && control & 0x01 != 0, isCopyPermitted: control & 0x02 != 0))
            case 0xA2 where session >= (leadOut?.session ?? 0):
                leadOut = (session, lba)
            default:
                break
            }
        }
        guard let leadOut else { throw .malformed }
        try self.init(tracks: tracks.sorted { $0.number < $1.number }, leadOutLBA: leadOut.lba)
    }
}

public enum TOCError: Error, Equatable {
    case malformed
    case noTracks
    case invalidTrackNumbers
    case invalidStart(track: Int)
    case invalidLeadOut
}
