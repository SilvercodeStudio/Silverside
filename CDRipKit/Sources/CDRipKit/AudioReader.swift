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
        /// Samples from sectors that could not be read. They are silence.
        public var unreadable: [Int] = []
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

    /// Reads the true samples at the given positions, with C2 error flags if `withC2`.
    /// If `unreadableRetries` is set, a sector that cannot be read is silence, not an error.
    public func read(_ positions: Range<Int>, withC2: Bool) throws -> Read {
        var result = Read(samples: [UInt32](repeating: 0, count: positions.count))
        guard !positions.isEmpty else { return result }

        // Sector L of the drive's data starts at true position L * 588 - readOffset.
        let firstSector = (positions.lowerBound + readOffset).floorDivided(by: CDDA.samplesPerSector)
        let endSector = (positions.upperBound + readOffset).ceilingDivided(by: CDDA.samplesPerSector)
        var sectors = firstSector..<endSector
        if !canOverread {
            sectors = sectors.clamped(to: 0..<toc.leadOutLBA)
        }

        for lba in stride(from: sectors.lowerBound, to: sectors.upperBound, by: sectorsPerRead) {
            let count = min(sectorsPerRead, sectors.upperBound - lba)
            let (bytes, flags, unreadable) = try readChunk(at: lba, count: count, withC2: withC2)
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
        }
        return result
    }

    private func readChunk(
        at lba: Int, count: Int, withC2: Bool
    ) throws -> (audio: [UInt8], errorFlags: [UInt8], unreadable: [Int]) {
        func read(_ lba: Int, _ count: Int) throws -> (audio: [UInt8], errorFlags: [UInt8]) {
            withC2
                ? try drive.readAudioSectorsWithC2(at: lba, count: count)
                : (try drive.readAudioSectors(at: lba, count: count), [])
        }
        do {
            let (audio, flags) = try read(lba, count)
            return (audio, flags, [])
        } catch DriveError.readFailed where unreadableRetries != nil {
            var audio = [UInt8]()
            var flags = [UInt8]()
            var unreadable = [Int]()
            for sector in lba..<(lba + count) {
                var data: (audio: [UInt8], errorFlags: [UInt8])?
                for _ in 0...unreadableRetries! where data == nil {
                    data = try? read(sector, 1)
                }
                if data == nil { unreadable.append(sector) }
                audio += data?.audio ?? [UInt8](repeating: 0, count: CDDA.bytesPerSector)
                if withC2 { flags += data?.errorFlags ?? [UInt8](repeating: 0, count: CDDA.errorFlagBytesPerSector) }
            }
            return (audio, flags, unreadable)
        }
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
