/// A drive that reads from a disc image in memory, for tests without hardware.
public final class SimulatedDrive: CDDrive {
    public let toc: TOC

    /// The true samples of the disc, from LBA 0 to the lead-out.
    public let samples: [UInt32]

    /// The drive's read offset in samples, as AccurateRip lists it. A drive
    /// with offset +N returns data N samples earlier than the sector asked for.
    public var readOffset: Int

    /// If true, the drive reads before LBA 0 and after the lead-out, and returns silence there.
    public var canOverread: Bool

    /// Sectors that fail with a read error when asked for.
    public var unreadableSectors: Set<Int> = []

    /// Physical sectors that return wrong data with no error.
    public var corruptSectors: Set<Int> = []

    /// The pregap (index 00) of each track in sectors, by track number. Track 1's
    /// pregap runs from LBA 0 to its start.
    public var pregaps: [Int: Int] = [:]

    /// Sectors whose Q subchannel has a bad CRC.
    public var corruptQSectors: Set<Int> = []

    /// The disc's MCN. If set, sectors whose LBA ends in 41 have an MCN frame in place of a position.
    public var mcn: String?

    /// ISRCs by track number. Sectors whose LBA ends in 83 have their track's ISRC frame, if it has one.
    public var isrcs: [Int: String] = [:]

    public init(toc: TOC, samples: [UInt32], readOffset: Int = 0, canOverread: Bool = false) {
        precondition(samples.count == toc.leadOutLBA * CDDA.samplesPerSector, "Image length does not match the TOC")
        self.toc = toc
        self.samples = samples
        self.readOffset = readOffset
        self.canOverread = canOverread
    }

    public func readTOC() throws -> TOC { toc }

    public func readAudioSectors(at lba: Int, count: Int) throws -> [UInt8] {
        let sectors = lba..<(lba + count)
        if !canOverread {
            if lba < 0 { throw DriveError.sectorOutOfRange(lba: lba) }
            if sectors.upperBound > toc.leadOutLBA { throw DriveError.sectorOutOfRange(lba: toc.leadOutLBA) }
        }
        if let bad = sectors.first(where: unreadableSectors.contains) {
            throw DriveError.readFailed(lba: bad)
        }

        var bytes = [UInt8]()
        bytes.reserveCapacity(count * CDDA.bytesPerSector)
        let firstPosition = lba * CDDA.samplesPerSector - readOffset
        for position in firstPosition..<(firstPosition + count * CDDA.samplesPerSector) {
            var sample = samples.indices.contains(position) ? samples[position] : 0
            if corruptSectors.contains(position.floorDivided(by: CDDA.samplesPerSector)) {
                sample ^= 0x0001_0001
            }
            withUnsafeBytes(of: sample.littleEndian) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }

    public func readQSubchannel(at lba: Int, count: Int) throws -> [QSubchannel] {
        let sectors = lba..<(lba + count)
        guard sectors.clamped(to: 0..<toc.leadOutLBA) == sectors else {
            throw DriveError.sectorOutOfRange(lba: sectors.first { !(0..<toc.leadOutLBA).contains($0) }!)
        }
        return sectors.map(frame(at:))
    }

    private func frame(at lba: Int) -> QSubchannel {
        let track = toc.tracks.last { $0.startLBA - (pregaps[$0.number] ?? 0) <= lba } ?? toc.tracks[0]
        let frame: QSubchannel
        if let mcn, lba % 100 == 41 {
            frame = .mcn(mcn)
        } else if let isrc = isrcs[track.number], lba % 100 == 83 {
            frame = .isrc(isrc)
        } else {
            frame = .position(track: track.number, index: lba < track.startLBA ? 0 : 1, lba: lba)
        }
        guard corruptQSectors.contains(lba) else { return frame }
        var bytes = frame.bytes
        bytes[1] ^= 0x80
        return QSubchannel(bytes: bytes)
    }
}
