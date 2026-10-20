/// How one ripped track compares with the AccurateRip database.
public enum AccurateRipVerification: Equatable, Sendable {
    /// The track matches. Each confidence is the number of submissions for that
    /// checksum version, or 0 if that version does not match.
    case accurate(v1Confidence: Int, v2Confidence: Int)
    /// The database has the disc, but no checksum for this track matches.
    case notAccurate
    /// The database does not have the disc, or it was not checked.
    case notChecked
}

/// One ripped track.
public struct TrackRip: Sendable {
    public var track: TOC.Track
    public var samples: [UInt32]
    public var checksum: AccurateRipChecksum
    public var verification: AccurateRipVerification
    /// The drive offsets at which this track matches AccurateRip. There can be
    /// more than one, because pressings of a disc are shifted against each other.
    public var matchingOffsets: [Int]
    /// The samples, by index in the track, that the drive flagged with C2 errors. Nil
    /// if the rip did not read C2 flags.
    public var c2Samples: [Int]?
    /// The samples, by index in the track, from sectors that could not be read. They are silence.
    public var unreadableSamples: [Int] = []
}

/// Rips tracks with offset correction and checks them against AccurateRip.
public struct TrackRipper {
    public let reader: AudioReader
    /// The disc's AccurateRip records. Empty if the disc is not in the database or the rip is offline.
    public let records: [AccurateRipRecord]
    /// If true, the first read of each track asks for C2 error flags. A drive that
    /// refuses gives a plain read.
    public var readsC2 = false

    /// Samples read before and after each track, so other offsets can be checked.
    /// AccurateRip skips this many samples at the disc's edges.
    static let margin = 5 * CDDA.samplesPerSector

    /// If the sector 450 checksum matches at more offsets than this, the sector is
    /// probably silent, and the matches say nothing.
    static let maximumFrame450Matches = 16

    public init(reader: AudioReader, records: [AccurateRipRecord]) {
        self.reader = reader
        self.records = records
    }

    /// Whether a track is the disc's first or last audio track, where AccurateRip skips samples.
    func edges(of track: TOC.Track) -> (isFirst: Bool, isLast: Bool) {
        let audio = reader.toc.audioTracks
        guard let index = audio.firstIndex(of: track) else { preconditionFailure("Not an audio track of this disc") }
        return (index == 0, index == audio.count - 1)
    }

    /// The AccurateRip records' entries for one track.
    func known(for track: TOC.Track) -> [AccurateRipRecord.Track] {
        guard let index = reader.toc.audioTracks.firstIndex(of: track) else { return [] }
        return records.compactMap { $0.tracks.indices.contains(index) ? $0.tracks[index] : nil }
    }

    /// How a track's checksum compares with the AccurateRip records' entries for the track.
    public static func verification(
        of checksum: AccurateRipChecksum, known: [AccurateRipRecord.Track]
    ) -> AccurateRipVerification {
        guard !known.isEmpty else { return .notChecked }
        let v1 = known.filter { $0.checksum == checksum.v1 }.reduce(0) { $0 + $1.confidence }
        let v2 = known.filter { $0.checksum == checksum.v2 }.reduce(0) { $0 + $1.confidence }
        return v1 + v2 > 0 ? .accurate(v1Confidence: v1, v2Confidence: v2) : .notAccurate
    }

    public func rip(_ track: TOC.Track) throws -> TrackRip {
        let toc = reader.toc
        let (isFirst, isLast) = edges(of: track)
        let sectors = toc.sectorRange(of: track)
        let start = sectors.lowerBound * CDDA.samplesPerSector
        let length = sectors.count * CDDA.samplesPerSector
        let margin = Self.margin

        let positions = (start - margin)..<(start + length + margin)
        var read: AudioReader.Read
        var flagged: [Int]?
        if readsC2, let withC2 = try? reader.read(positions, withC2: true) {
            (read, flagged) = (withC2, withC2.flagged)
        } else {
            read = try reader.read(positions, withC2: false)
        }
        let buffer = read.samples
        // The checksum of the track as if the drive's offset were `shift` samples more.
        func checksum(shiftedBy shift: Int) -> AccurateRipChecksum {
            let window = Array(buffer[(margin + shift)..<(margin + shift + length)])
            return AccurateRipAccumulator.checksum(of: window.span, isFirstTrack: isFirst, isLastTrack: isLast)
        }

        let known = known(for: track)
        func verification(of checksum: AccurateRipChecksum) -> AccurateRipVerification {
            Self.verification(of: checksum, known: known)
        }

        let samples = Array(buffer[margin..<(margin + length)])
        let trackChecksum = AccurateRipAccumulator.checksum(
            of: samples.span, isFirstTrack: isFirst, isLastTrack: isLast)
        let trackVerification = verification(of: trackChecksum)

        // Find other offsets that match, then check each with the whole track's checksums.
        var shifts = Set<Int>()
        if !known.isEmpty {
            if length >= 451 * CDDA.samplesPerSector {
                let frame450 = AccurateRipOffsetFinder.frame450Offsets(
                    matching: Set(known.map(\.frame450Checksum)), in: buffer, trackLength: length, margin: margin)
                if frame450.count <= Self.maximumFrame450Matches { shifts.formUnion(frame450) }
            }
            if !isFirst && !isLast {
                shifts.formUnion(
                    AccurateRipOffsetFinder.offsets(
                        matching: Set(known.map(\.checksum)), in: buffer, trackLength: length, margin: margin))
            }
        }
        var matchingOffsets = [Int]()
        for shift in shifts.union([0]).sorted() {
            let result = shift == 0 ? trackVerification : verification(of: checksum(shiftedBy: shift))
            if case .accurate = result { matchingOffsets.append(reader.readOffset + shift) }
        }

        return TrackRip(
            track: track, samples: samples, checksum: trackChecksum, verification: trackVerification,
            matchingOffsets: matchingOffsets,
            c2Samples: flagged?.map { $0 - margin }.filter { (0..<length).contains($0) },
            unreadableSamples: read.unreadable.map { $0 - margin }.filter { (0..<length).contains($0) })
    }
}
