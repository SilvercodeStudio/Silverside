import Foundation

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

    /// Sectors that fail with a read error the given number of times more, then read. A
    /// request of several sectors that holds one counts as one time for the first such sector.
    public var failingReads: [Int: Int] = [:]

    /// If true, a read of a sector outside the disc's audio areas (a data track, or the
    /// session gap of an enhanced CD) fails with a read error, as on real drives.
    public var failsOutsideAudio = true

    /// Physical sectors that return wrong data with no error, the same on every read.
    public var corruptSectors: Set<Int> = []

    /// The drive's speed over 1× (75 sectors per second). Nil reads at once; a speed makes
    /// each read take the time a drive would, for the app's progress display.
    public var readSpeed: Double?

    /// Physical sectors that return wrong data and the true data in turn, starting
    /// with wrong data, on each read that does not come from the cache. A damaged
    /// sector of "Europe '72" did this on the MATSHITA.
    public var unstableSectors: Set<Int> = []

    /// A place where the drive loses its place, as on a scratch: on the `onPass`th read
    /// from the disc that passes physical sector `sector`, the data from that sector on
    /// comes from `shift` samples further on, until a request that does not continue the read.
    public struct Slip: Sendable {
        public var sector: Int
        public var shift: Int
        public var onPass: Int

        public init(sector: Int, shift: Int, onPass: Int) {
            self.sector = sector
            self.shift = shift
            self.onPass = onPass
        }
    }

    public var slips: [Slip] = []
    private var slipPasses: [Int: (count: Int, request: Int)] = [:]
    /// The shift of a slip in this read, and the sample position where it starts.
    private var activeSlip: (shift: Int, from: Int)?
    private var lastRequestEnd: Int?

    /// The disc's CD-Text, as a drive gives it: a 4-byte header, then 18-byte packs.
    public var cdText: [UInt8]?

    public func readCDText() throws -> [UInt8]? { cdText }

    /// What the disc is. Nil makes the drive one that cannot tell.
    public var mediaType: DiscMediaType? = .pressed

    public func readMediaType() throws -> DiscMediaType? { mediaType }

    /// If true, C2 reads flag the bytes of corrupt and unstable sectors that read wrong.
    public var reportsC2 = false

    /// How many sectors the drive caches. A read of sectors that are all in the
    /// cache returns the cached data, as real drives do, and the cache removes the
    /// sectors used least recently. Zero turns the cache off.
    public var cacheSectors = 0

    /// The number of read requests that the cache did not answer.
    public private(set) var discReads = 0

    /// True if the cache answered the last read request.
    public private(set) var lastReadWasCached = false

    private var cache: [Int: (audio: [UInt8], errorFlags: [UInt8])] = [:]
    private var cacheOrder: [Int] = []
    /// For each unstable sector: how many times it was read from the disc, and the
    /// read request that last touched it.
    private var unstableReads: [Int: (count: Int, request: Int)] = [:]

    /// The pregap (index 00) of each track in sectors, by track number. Track 1's
    /// pregap runs from LBA 0 to its start.
    public var pregaps: [Int: Int] = [:]

    /// Index points after 01, by track number: the LBAs where its index 02, 03, and so on start.
    public var indexes: [Int: [Int]] = [:]

    /// Sectors whose Q subchannel has a damaged track number and a bad CRC.
    public var corruptQSectors: Set<Int> = []

    /// Sectors whose Q subchannel has correct contents but a bad CRC, as some discs
    /// have just before each track change.
    public var badCRCQSectors: Set<Int> = []

    /// The disc's MCN. If set, sectors whose LBA ends in 41 have an MCN frame in place of a position.
    public var mcn: String?

    /// ISRCs by track number. Sectors whose LBA ends in 83 have their track's ISRC frame, if it has one.
    public var isrcs: [Int: String] = [:]

    /// The control bits in the Q frames of each track, by track number (see `QSubchannel.control`),
    /// whatever the TOC says. A track that is not here has none.
    public var qControl: [Int: UInt8] = [:]

    public init(toc: TOC, samples: [UInt32], readOffset: Int = 0, canOverread: Bool = false) {
        precondition(samples.count == toc.leadOutLBA * CDDA.samplesPerSector, "Image length does not match the TOC")
        self.toc = toc
        self.samples = samples
        self.readOffset = readOffset
        self.canOverread = canOverread
    }

    public func readTOC() throws -> TOC { toc }

    public func readAudioSectors(at lba: Int, count: Int) throws -> [UInt8] {
        try readAudioSectorsWithC2(at: lba, count: count).audio
    }

    /// Flags the bytes that it returns wrong, if `reportsC2` is true.
    public func readAudioSectorsWithC2(at lba: Int, count: Int) throws -> (audio: [UInt8], errorFlags: [UInt8]) {
        let sectors = lba..<(lba + count)
        if let readSpeed, readSpeed > 0 {
            Thread.sleep(forTimeInterval: Double(count) / (readSpeed * Double(CDDA.sectorsPerSecond)))
        }
        if !canOverread {
            if lba < 0 { throw DriveError.sectorOutOfRange(lba: lba) }
            if sectors.upperBound > toc.leadOutLBA { throw DriveError.sectorOutOfRange(lba: toc.leadOutLBA) }
        }
        if let bad = sectors.first(where: unreadableSectors.contains) {
            throw DriveError.readFailed(lba: bad)
        }
        if let bad = sectors.first(where: { (failingReads[$0] ?? 0) > 0 }) {
            failingReads[bad]! -= 1
            throw DriveError.readFailed(lba: bad)
        }
        if failsOutsideAudio {
            let areas = toc.audioAreas
            let onDisc = sectors.clamped(to: 0..<toc.leadOutLBA)
            if let bad = onDisc.first(where: { lba in !areas.contains { $0.contains(lba) } }) {
                throw DriveError.readFailed(lba: bad)
            }
        }
        if cacheSectors > 0, sectors.allSatisfy({ cache[$0] != nil }) {
            lastReadWasCached = true
            touch(sectors)
            return (sectors.flatMap { cache[$0]!.audio }, sectors.flatMap { cache[$0]!.errorFlags })
        }
        lastReadWasCached = false
        discReads += 1

        // A sector that the request just before also touched is part of the same
        // continuous read, as a drive reads ahead, so it keeps its data.
        let firstPosition = lba * CDDA.samplesPerSector - readOffset
        let firstSector = firstPosition.floorDivided(by: CDDA.samplesPerSector)
        let lastSector = (firstPosition + count * CDDA.samplesPerSector - 1).floorDivided(by: CDDA.samplesPerSector)
        var wrongThisRead = Set<Int>()
        for sector in firstSector...lastSector where unstableSectors.contains(sector) {
            var state = unstableReads[sector] ?? (count: 0, request: -2)
            if state.request != discReads - 1 { state.count += 1 }
            state.request = discReads
            unstableReads[sector] = state
            if state.count % 2 == 1 { wrongThisRead.insert(sector) }
        }

        if lastRequestEnd != lba { activeSlip = nil }
        lastRequestEnd = lba + count
        for (index, slip) in slips.enumerated() where (firstSector...lastSector).contains(slip.sector) {
            var state = slipPasses[index] ?? (count: 0, request: -2)
            if state.request != discReads - 1 { state.count += 1 }
            state.request = discReads
            slipPasses[index] = state
            if state.count == slip.onPass && activeSlip == nil {
                activeSlip = (slip.shift, slip.sector * CDDA.samplesPerSector)
            }
        }

        var bytes = [UInt8]()
        bytes.reserveCapacity(count * CDDA.bytesPerSector)
        var flags = [UInt8](repeating: 0, count: count * CDDA.errorFlagBytesPerSector)
        for position in firstPosition..<(firstPosition + count * CDDA.samplesPerSector) {
            let source = activeSlip.map { position >= $0.from ? position + $0.shift : position } ?? position
            var sample = samples.indices.contains(source) ? samples[source] : 0
            let sector = position.floorDivided(by: CDDA.samplesPerSector)
            if corruptSectors.contains(sector) || wrongThisRead.contains(sector) {
                sample ^= 0x0001_0001
                if reportsC2 {
                    // The low bytes of the left and right values are wrong.
                    let byte = (position - firstPosition) * CDDA.bytesPerSample
                    flags[byte / 8] |= 0x80 >> (byte % 8) | 0x80 >> ((byte + 2) % 8)
                }
            }
            withUnsafeBytes(of: sample.littleEndian) { bytes.append(contentsOf: $0) }
        }
        if cacheSectors > 0 {
            touch(sectors)
            for (index, sector) in sectors.enumerated() {
                let start = index * CDDA.bytesPerSector
                let flagStart = index * CDDA.errorFlagBytesPerSector
                cache[sector] = (
                    Array(bytes[start..<(start + CDDA.bytesPerSector)]),
                    Array(flags[flagStart..<(flagStart + CDDA.errorFlagBytesPerSector)])
                )
            }
            while cacheOrder.count > cacheSectors { cache[cacheOrder.removeFirst()] = nil }
        }
        return (bytes, flags)
    }

    /// Makes `sectors` the most recently used, so the cache removes them last.
    private func touch(_ sectors: Range<Int>) {
        cacheOrder.removeAll { sectors.contains($0) }
        cacheOrder.append(contentsOf: sectors)
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
            frame = .position(
                track: track.number,
                index: lba < track.startLBA ? 0 : 1 + (indexes[track.number] ?? []).filter { $0 <= lba }.count,
                lba: lba,
                control: qControl[track.number] ?? 0)
        }
        var bytes = frame.bytes
        if corruptQSectors.contains(lba) {
            bytes[1] ^= 0x80
        } else if badCRCQSectors.contains(lba) {
            bytes[11] ^= 0x01
        } else {
            return frame
        }
        return QSubchannel(bytes: bytes)
    }
}
