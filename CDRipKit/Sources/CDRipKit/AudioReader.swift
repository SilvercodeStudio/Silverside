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

    public init(drive: any CDDrive, toc: TOC, readOffset: Int, canOverread: Bool) {
        self.drive = drive
        self.toc = toc
        self.readOffset = readOffset
        self.canOverread = canOverread
    }

    /// Reads the true samples at the given positions (588 samples for each sector, from LBA 0).
    public func readSamples(_ positions: Range<Int>) throws -> [UInt32] {
        var result = [UInt32](repeating: 0, count: positions.count)
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
            let chunk = CDDA.samples(fromSectorBytes: try drive.readAudioSectors(at: lba, count: count))
            let chunkStart = lba * CDDA.samplesPerSector - readOffset
            let overlap = (chunkStart..<(chunkStart + chunk.count)).clamped(to: positions)
            guard !overlap.isEmpty else { continue }
            result.replaceSubrange(
                (overlap.lowerBound - positions.lowerBound)..<(overlap.upperBound - positions.lowerBound),
                with: chunk[(overlap.lowerBound - chunkStart)..<(overlap.upperBound - chunkStart)]
            )
        }
        return result
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
