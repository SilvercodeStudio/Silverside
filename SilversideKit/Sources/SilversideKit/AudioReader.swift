/// Reads audio from a drive and corrects the drive's read offset, so that
/// sample positions agree with the true positions on the disc.
public struct AudioReader {
    public let drive: any CDDrive
    public let toc: TOC

    /// The drive's read offset in samples, as AccurateRip lists it.
    public let readOffset: Int

    /// If true, read before LBA 0 and after the lead-out. If false, those samples are silence.
    public let canOverread: Bool

    /// Sectors for each read command. 26 sectors (61,152 bytes) is less than the
    /// 64 KB transfer limit of many USB bridges.
    public var sectorsPerRead = 26

    /// If set, a chunk that cannot be read is read again sector by sector, each up to this
    /// many more times. A sector that still fails is silence, and `Read.unreadable` lists it.
    /// If nil, the read throws.
    public var unreadableRetries: Int?

    /// If set, a read checks it before each chunk, and throws `CancellationError` once it is stopped.
    public var stop: StopToken?

    public init(drive: any CDDrive, toc: TOC, readOffset: Int, canOverread: Bool) {
        self.drive = drive
        self.toc = toc
        self.readOffset = readOffset
        self.canOverread = canOverread
    }

    /// The result of a read: the samples, and the indexes in `samples` of samples that
    /// may be wrong.
    public struct Read: Sendable {
        public var samples: [UInt32]
        /// Samples with a byte that the drive flagged with a C2 error.
        public var flagged: [Int] = []
        /// True only if every chunk supplied the requested C2 flags.
        public var c2Available = false
        /// Samples from sectors that could not be read. They are silence.
        public var unreadable: [Int] = []
        /// The Q subchannel frames of the sectors read, if asked for: as the drive returned them,
        /// in the order read. Empty if the drive refused to read them with the audio.
        public var q: [QSubchannel] = []
    }

    /// Reads the true samples at the given positions (588 samples for each sector, from LBA 0).
    public func readSamples(_ positions: Range<Int>) throws -> [UInt32] {
        try read(positions, withC2: false).samples
    }

    /// Reads the true samples at the given positions, with the drive's C2 error flags.
    /// `flagged` holds the indexes in `samples` of the samples with a flagged byte.
    public func readSamplesWithC2(_ positions: Range<Int>) throws -> (samples: [UInt32], flagged: [Int]) {
        let read = try read(positions, withC2: true)
        return (read.samples, read.flagged)
    }

    /// Reads the true samples at the given positions, with C2 error flags if `withC2`, and the
    /// sectors' Q frames if `withQ`. If `unreadableRetries` is set, a sector that cannot be read
    /// is silence, not an error.
    public func read(
        _ positions: Range<Int>, withC2: Bool, withQ: Bool = false, progress: ((ReadProgress) -> Void)? = nil
    ) throws -> Read {
        var result = Read(samples: [UInt32](repeating: 0, count: positions.count))
        result.c2Available = withC2
        guard !positions.isEmpty else { return result }

        // Sector L of the drive's data starts at true position L * 588 - readOffset.
        let firstSector = (positions.lowerBound + readOffset).floorDivided(by: CDDA.samplesPerSector)
        let endSector = (positions.upperBound + readOffset).ceilingDivided(by: CDDA.samplesPerSector)
        let wanted = firstSector..<endSector
        // Without overread, sectors outside the disc's audio (past its edges, in a data track,
        // or in the session gap of an enhanced CD) are not read: their samples stay silence.
        let parts = canOverread ? [wanted] : toc.audioAreas.map { wanted.clamped(to: $0) }.filter { !$0.isEmpty }
        let total = parts.reduce(0) { $0 + $1.count }

        var sectorsRead = 0
        var flaggedSectors = Set<Int>()
        var unreadableSectors = Set<Int>()
        var extras = Extras(c2: withC2, q: withQ)
        // Include optional payloads in the USB transfer limit, not just the audio.
        let sectorBytes = CDDA.bytesPerSector + (withC2 ? CDDA.errorFlagBytesPerSector : 0) + (withQ ? 16 : 0)
        let chunkSize = max(1, min(sectorsPerRead, 65_536 / sectorBytes))
        for part in parts {
            for lba in stride(from: part.lowerBound, to: part.upperBound, by: chunkSize) {
                try stop?.check()
                let count = min(chunkSize, part.upperBound - lba)
                let (sectors, unreadable, hasFlags) = try readChunk(at: lba, count: count, extras: &extras)
                if withC2 && !hasFlags { result.c2Available = false }
                let (bytes, flags) = (sectors.audio, sectors.errorFlags)
                result.q += sectors.q
                sectorsRead += count
                let chunk = CDDA.samples(fromSectorBytes: bytes)
                let chunkStart = lba * CDDA.samplesPerSector - readOffset
                let overlap = (chunkStart..<(chunkStart + chunk.count)).clamped(to: positions)
                guard !overlap.isEmpty else { continue }
                result.samples.replaceSubrange(
                    (overlap.lowerBound - positions.lowerBound)..<(overlap.upperBound - positions.lowerBound),
                    with: chunk[(overlap.lowerBound - chunkStart)..<(overlap.upperBound - chunkStart)]
                )
                // Each sample has 4 bytes, so half a flag byte: the high half for even samples.
                for (index, flag) in flags.enumerated() where flag != 0 {
                    for (half, mask) in [(0, UInt8(0xF0)), (1, UInt8(0x0F))] where flag & mask != 0 {
                        let position = chunkStart + 2 * index + half
                        if overlap.contains(position) { result.flagged.append(position - positions.lowerBound) }
                    }
                }
                for sector in unreadable {
                    let start = sector * CDDA.samplesPerSector - readOffset
                    for position in (start..<(start + CDDA.samplesPerSector)).clamped(to: overlap) {
                        result.unreadable.append(position - positions.lowerBound)
                    }
                }
                if let progress {
                    let flaggedInChunk = Set(
                        flags.indices.filter { flags[$0] != 0 }.map { lba + $0 / CDDA.errorFlagBytesPerSector }
                    ).sorted()
                    flaggedSectors.formUnion(flaggedInChunk)
                    unreadableSectors.formUnion(unreadable)
                    progress(
                        ReadProgress(
                            sectorsRead: sectorsRead, sectors: total, flaggedSectors: flaggedSectors.count,
                            unreadableSectors: unreadableSectors.count, chunk: lba..<(lba + count),
                            flaggedInChunk: flaggedInChunk, unreadableInChunk: unreadable.sorted()))
                }
            }
        }
        return result
    }

    /// What a read asks of the drive besides the audio, and what the drive has shown that it
    /// gives. Some drives and USB bridges refuse the C2 flags or the Q subchannel, and some
    /// report a refusal as EIO, as they report damaged audio. So a read that asks for a part
    /// and fails is tried without it, until a read with it works: from then on, a failure is
    /// the disc's. Only a second refusal stops the requests, so that a damaged sector early in
    /// a track does not cost the rest of the track its flags or its Q frames.
    private struct Extras {
        var c2: Bool
        var q: Bool
        var c2Works = false
        var qWorks = false
        var c2Refusals = 0
        var qRefusals = 0
        static let refusalsToStop = 2
    }

    /// Reads one chunk. If it fails, and `unreadableRetries` is set, reads it sector by
    /// sector. `hasFlags` is false if a sector that was read came without its C2 flags.
    private func readChunk(
        at lba: Int, count: Int, extras: inout Extras
    ) throws -> (sectors: SectorRead, unreadable: [Int], hasFlags: Bool) {
        let flagBytes = CDDA.errorFlagBytesPerSector
        do {
            let sectors = try readRaw(at: lba, count: count, extras: &extras)
            return (sectors, [], sectors.errorFlags.count == count * flagBytes)
        } catch DriveError.readFailed where unreadableRetries != nil {
            var sectors = SectorRead(audio: [])
            let wantsFlags = extras.c2
            var hasFlags = true
            var unreadable = [Int]()
            for sector in lba..<(lba + count) {
                var data: SectorRead?
                for _ in 0...max(0, unreadableRetries!) where data == nil {
                    try stop?.check()
                    do {
                        data = try readRaw(at: sector, count: 1, extras: &extras)
                    } catch DriveError.readFailed {
                        continue
                    }
                }
                if data == nil { unreadable.append(sector) }
                sectors.audio += data?.audio ?? [UInt8](repeating: 0, count: CDDA.bytesPerSector)
                if wantsFlags {
                    // An unreadable sector has no flags: `unreadable` lists it instead.
                    if let data, data.errorFlags.count != flagBytes { hasFlags = false }
                    sectors.errorFlags +=
                        data?.errorFlags.count == flagBytes
                        ? data!.errorFlags : [UInt8](repeating: 0, count: flagBytes)
                }
                sectors.q += data?.q ?? []
            }
            return (sectors, unreadable, hasFlags)
        }
    }

    /// Reads sectors with the parts that `extras` asks for. If that fails, tries again
    /// without the parts that the drive has not given yet, one at a time and then together,
    /// and counts a read that then works as a refusal of each part left out.
    private func readRaw(at lba: Int, count: Int, extras: inout Extras) throws -> SectorRead {
        // As asked, then without Q, without C2, and without both, for each part not yet given:
        // a drive that refuses one part keeps the other.
        let c2Choices = extras.c2 && !extras.c2Works ? [true, false] : [extras.c2]
        let qChoices = extras.q && !extras.qWorks ? [true, false] : [extras.q]
        let attempts = c2Choices.flatMap { c2 in qChoices.map { q in (c2: c2, q: q) } }
        var failure: any Error = DriveError.readFailed(lba: lba)
        for attempt in attempts {
            do {
                let read = try drive.readAudioSectors(at: lba, count: count, c2: attempt.c2, q: attempt.q)
                if attempt.q { extras.qWorks = true }
                if attempt.c2 { extras.c2Works = true }
                if extras.q && !attempt.q {
                    extras.qRefusals += 1
                    if extras.qRefusals >= Extras.refusalsToStop { extras.q = false }
                }
                if extras.c2 && !attempt.c2 {
                    extras.c2Refusals += 1
                    if extras.c2Refusals >= Extras.refusalsToStop { extras.c2 = false }
                }
                return read
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = error
            }
        }
        throw failure
    }

    public func readTrack(_ track: TOC.Track) throws -> [UInt32] {
        let sectors = toc.sectorRange(of: track)
        return try readSamples(
            (sectors.lowerBound * CDDA.samplesPerSector)..<(sectors.upperBound * CDDA.samplesPerSector))
    }
}

extension Int {
    func floorDivided(by divisor: Int) -> Int {
        let quotient = self / divisor
        return (self % divisor != 0 && (self < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }

    func ceilingDivided(by divisor: Int) -> Int {
        -(-self).floorDivided(by: divisor)
    }
}
