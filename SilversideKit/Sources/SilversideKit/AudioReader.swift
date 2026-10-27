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
        var withQ = withQ
        var c2 = withC2
        // Include optional payloads in the USB transfer limit, not just the audio.
        let sectorBytes = CDDA.bytesPerSector + (withC2 ? CDDA.errorFlagBytesPerSector : 0) + (withQ ? 16 : 0)
        let chunkSize = max(1, min(sectorsPerRead, 65_536 / sectorBytes))
        for part in parts {
            for lba in stride(from: part.lowerBound, to: part.upperBound, by: chunkSize) {
                try stop?.check()
                let count = min(chunkSize, part.upperBound - lba)
                let (sectors, unreadable) = try readChunk(at: lba, count: count, withC2: &c2, withQ: &withQ)
                if !c2 { result.c2Available = false }
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

    /// Try optional read areas before classifying an audio sector as unreadable. Some bridges
    /// report unsupported Q/C2 combinations as EIO, the same error as damaged audio.
    private func readChunk(
        at lba: Int, count: Int, withC2: inout Bool, withQ: inout Bool
    ) throws -> (sectors: SectorRead, unreadable: [Int]) {
        do {
            return (try readRaw(at: lba, count: count, withC2: &withC2, withQ: &withQ), [])
        } catch DriveError.readFailed where unreadableRetries != nil {
            var sectors = SectorRead(audio: [])
            let wantsFlags = withC2
            var unreadable = [Int]()
            for sector in lba..<(lba + count) {
                var data: SectorRead?
                for _ in 0...max(0, unreadableRetries!) where data == nil {
                    try stop?.check()
                    do { data = try readRaw(at: sector, count: 1, withC2: &withC2, withQ: &withQ) } catch DriveError
                        .readFailed
                    { continue }
                }
                if data == nil { unreadable.append(sector) }
                sectors.audio += data?.audio ?? [UInt8](repeating: 0, count: CDDA.bytesPerSector)
                if wantsFlags {
                    let flags = data?.errorFlags ?? []
                    sectors.errorFlags +=
                        flags.count == CDDA.errorFlagBytesPerSector
                        ? flags : [UInt8](repeating: 0, count: CDDA.errorFlagBytesPerSector)
                }
                sectors.q += data?.q ?? []
            }
            return (sectors, unreadable)
        }
    }

    private func readRaw(at lba: Int, count: Int, withC2: inout Bool, withQ: inout Bool) throws -> SectorRead {
        if withQ {
            do {
                return try drive.readAudioSectors(at: lba, count: count, c2: withC2, q: true)
            } catch is CancellationError { throw CancellationError() } catch {
                // Establish whether the audio reads without Q before substituting silence.
            }
        }
        if withC2 {
            do {
                let read = try drive.readAudioSectors(at: lba, count: count, c2: true, q: false)
                withQ = false
                return read
            } catch is CancellationError { throw CancellationError() } catch {
                // A plain audio read distinguishes C2 capability failures from damaged audio.
            }
        }
        let read = try drive.readAudioSectors(at: lba, count: count, c2: false, q: false)
        withQ = false
        withC2 = false
        return read
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
