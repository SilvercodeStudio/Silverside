/// How one ripped track compares with the AccurateRip database.
public enum AccurateRipVerification: Equatable, Sendable {
    /// The track matches. Each confidence is the number of submissions for that
    /// checksum version, or 0 if that version does not match.
    case accurate(v1Confidence: Int, v2Confidence: Int)
    /// The database has the disc, but no checksum for this track matches.
    case notAccurate
    /// The database does not have the disc, or it was not checked.
    case notChecked

    /// True for a match that holds up where many candidates were tested (the secure ripper's
    /// search of sector versions), or the audio came from such a test (an earlier rip's
    /// file): both checksums match, or the checksum is one of the track's best-supported.
    /// One of thousands of wrong combinations can match a 32-bit checksum by chance, most
    /// likely one of the many that few rips have.
    public func isProof(among known: [AccurateRipRecord.Track]) -> Bool {
        guard case .accurate(let v1, let v2) = self else { return false }
        return (v1 > 0 && v2 > 0) || max(v1, v2) >= (known.map(\.confidence).max() ?? 0)
    }
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
    /// The control bits of the track's Q frames in the read. Nil if the drive did not read them.
    public var subchannel: SubchannelControl?
    /// The positions in the valid ADR 1 frames of the read, the track's and the next pregap's,
    /// for its index points (`PregapFinder.indexes`). Empty if the drive did not read Q frames.
    public var qPositions: [QSubchannel.Position] = []
    /// True if the read took Q from some chunks only, found an index after 01 there, and so
    /// read the track's whole Q subchannel again (`TrackRipper.qEvery`).
    public var qReadInFull = false
}

/// Rips tracks with offset correction and checks them against AccurateRip.
public struct TrackRipper {
    public let reader: AudioReader
    /// The disc's AccurateRip records. Empty if the disc is not in the database or the rip is offline.
    public let records: [AccurateRipRecord]
    /// If true, the first read of each track asks for C2 error flags. A drive that
    /// refuses gives a plain read.
    public var readsC2 = false
    /// If true, the first read of each track reads its Q subchannel too, for the control bits
    /// (pre-emphasis, copy permitted, four-channel). A drive that refuses gives a read without it.
    public var readsQ = true

    /// The first read takes Q from every `qEvery`-th chunk: 1 for every chunk. Some drives read
    /// at half speed with Q (`DriveProfile.qReadCost`), so they take it from some chunks only:
    /// enough frames for the control bits, and for any index that lasts longer than
    /// `qEvery + 1` chunks. A track where those frames show an index after 01 then has its whole
    /// Q subchannel read, so that a shorter index next to it is not missed.
    public var qEvery = 1

    /// `qEvery` for a drive whose reads with Q take this many times as long as without, or
    /// 1 if they cost little more (MATSHITA and ASUS: no more; GUC0N and PLDS DS8A5SH: 2.2).
    public static func qEvery(forReadCost cost: Double?) -> Int {
        guard let cost, cost >= 1.6 else { return 1 }
        return 6
    }

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
        return records.entries(forTrackAt: index)
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

    /// Rips a track. `progress` hears about the read as it goes; `passes` is how many reads
    /// of the track there can be in all, for the event.
    public func rip(_ track: TOC.Track, passes: Int = 1, progress: ((RipEvent) -> Void)? = nil) throws -> TrackRip {
        let toc = reader.toc
        let (isFirst, isLast) = edges(of: track)
        let sectors = toc.sectorRange(of: track)
        let start = sectors.lowerBound * CDDA.samplesPerSector
        let length = sectors.count * CDDA.samplesPerSector
        let margin = Self.margin

        let positions = (start - margin)..<(start + length + margin)
        var read: AudioReader.Read
        var flagged: [Int]?
        let readOffset = reader.readOffset
        let report = progress.map { progress in
            { (read: ReadProgress) in
                progress(
                    .reading(
                        track: track.number, pass: 1, passes: passes,
                        progress: read.inTrack(startingAt: start, readOffset: readOffset))
                )
            }
        }
        if readsC2,
            let withC2 = try? reader.read(positions, withC2: true, withQ: readsQ, qEvery: qEvery, progress: report)
        {
            // Flags that the drive gave count even if some chunks came without them.
            (read, flagged) = (withC2, withC2.c2Available || !withC2.flagged.isEmpty ? withC2.flagged : nil)
        } else {
            read = try reader.read(positions, withC2: false, withQ: readsQ, qEvery: qEvery, progress: report)
        }
        var frames = read.q
        var qReadInFull = false
        if readsQ && qEvery > 1
            && frames.contains(where: { $0.position.map { $0.track == track.number && $0.index >= 2 } ?? false })
        {
            let full = try reader.readQ(sectors) { done, count in
                progress?(
                    .readingIndexes(
                        track: track.number,
                        progress: ReadProgress(
                            sectorsRead: done, sectors: count, flaggedSectors: 0, unreadableSectors: 0)
                    ))
            }
            // The sampled frames stay where this read got none (a chunk that failed), and no frame counts twice.
            let fullLBAs = Set(full.compactMap(\.position?.lba))
            frames = full + frames.filter { $0.position.map { !fullLBAs.contains($0.lba) } ?? false }
            qReadInFull = true
        }
        var subchannel = SubchannelControl()
        subchannel.add(frames, track: track.number)
        let buffer = read.samples
        // The checksum of the track as if the drive's offset were `shift` samples more.
        func checksum(shiftedBy shift: Int) -> AccurateRipChecksum {
            AccurateRipAccumulator.checksum(
                of: buffer[(margin + shift)..<(margin + shift + length)], isFirstTrack: isFirst, isLastTrack: isLast)
        }

        let known = known(for: track)
        func verification(of checksum: AccurateRipChecksum) -> AccurateRipVerification {
            Self.verification(of: checksum, known: known)
        }

        let samples = Array(buffer[margin..<(margin + length)])
        let trackChecksum = AccurateRipAccumulator.checksum(
            of: samples[...], isFirstTrack: isFirst, isLastTrack: isLast)
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
            unreadableSamples: read.unreadable.map { $0 - margin }.filter { (0..<length).contains($0) },
            subchannel: subchannel.frames > 0 ? subchannel : nil, qPositions: frames.compactMap(\.position),
            qReadInFull: qReadInFull)
    }
}
