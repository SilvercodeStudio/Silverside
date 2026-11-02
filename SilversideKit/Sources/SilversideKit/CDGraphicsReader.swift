import Foundation

/// Saves a track's CD+G graphics: the raw subchannel of its sectors, de-interleaved into packs,
/// checked and corrected by their parity (`CDGraphics.checkedPacks`), as a `.cdg` file: 24
/// bytes a pack, four packs a sector, 300 a second from the track's index 01, the form that
/// karaoke players and FFmpeg read. The file keeps every pack, CD+EG's too, so a player
/// that knows only CD+G passes over those.
public enum CDGraphicsReader {
    /// Sectors in each read: as many as `DiscProbe` reads, so that a stop does not wait long.
    static let chunk = 25

    /// Reads the subchannel of `track` (index 01 to the next track's) and writes its packs to
    /// `url`. The packs of a sector are spread over the next 7 packs, so the read goes on 2
    /// sectors past the track where the disc's audio goes on. Nil, and no file, if the track
    /// has no graphics. Throws if the drive gives none of the subchannel: a drive that
    /// refuses it fails every read. Read it before the track's audio: the MATSHITA gives
    /// the wrong subchannel for sectors it has just read as audio.
    public static func read(
        _ track: TOC.Track, in toc: TOC, drive: any CDDrive, to url: URL, stop: StopToken? = nil,
        progress: (Double) -> Void = { _ in }
    ) throws -> RipReport.Graphics? {
        let range = toc.sectorRange(of: track)
        let area = toc.audioAreas.first { $0.contains(range.lowerBound) } ?? range
        let end = min(range.upperBound + 2, max(area.upperBound, range.upperBound))
        var misplacedReads = 0
        var pw = [UInt8]()
        pw.reserveCapacity((end - range.lowerBound) * 96)
        var unreadable = [Int]()
        var lba = range.lowerBound
        while lba < end {
            try stop?.check()
            let count = min(chunk, end - lba)
            // A read again, up to 3 times, when the Q frames show that the drive gave another
            // place's subchannel, or none: after a track's audio, the MATSHITA answered the next
            // 450 sectors' reads with no valid Q frame and R–W that failed every parity
            // (2026-11-02, a rip of *Information Society*). A read far away first makes the
            // drive read the disc again.
            var bytes: [UInt8]?
            var misplaced = [Int]()
            for attempt in 0..<4 {
                if attempt > 0 {
                    misplacedReads += 1
                    _ = try? drive.readSubchannelPW(at: away(from: lba, in: toc), count: 1)
                }
                bytes = try? drive.readSubchannelPW(at: lba, count: count)
                guard let read = bytes, read.count == count * 96 else {
                    bytes = nil
                    break
                }
                let frames = qFrames(read, from: lba)
                misplaced = frames.misplaced
                if misplaced.isEmpty && frames.valid * 2 >= count { break }
            }
            if var read = bytes {
                // Sectors still misplaced are left out, as unreadable.
                for sector in misplaced {
                    read.replaceSubrange(
                        ((sector - lba) * 96)..<((sector - lba + 1) * 96), with: repeatElement(0, count: 96))
                    if sector < range.upperBound { unreadable.append(sector - range.lowerBound) }
                }
                pw += read
            } else {
                // Sector by sector, so that one bad sector costs only its own packs.
                for sector in lba..<(lba + count) {
                    if let read = try? drive.readSubchannelPW(at: sector, count: 1), read.count == 96,
                        qFrames(read, from: sector).misplaced.isEmpty
                    {
                        pw += read
                    } else {
                        pw += [UInt8](repeating: 0, count: 96)
                        if sector < range.upperBound { unreadable.append(sector - range.lowerBound) }
                    }
                }
            }
            lba += count
            progress(Double(lba - range.lowerBound) / Double(end - range.lowerBound))
        }
        if unreadable.count == range.count { throw DriveError.readFailed(lba: range.lowerBound) }

        var packs = Array(CDGraphics.packs(pw).prefix(range.count * 4))
        if packs.count < range.count * 4 {
            packs += Array(repeating: [UInt8](repeating: 0, count: 24), count: range.count * 4 - packs.count)
        }
        var corrected = 0
        var damaged = [Int]()
        for i in packs.indices {
            switch CDGraphics.check(&packs[i]) {
            case .valid: break
            case .corrected: corrected += 1
            case .uncorrectable: damaged.append(i)
            }
        }
        // A damaged pack is read again, up to 3 times: the subchannel has no error correction
        // but the packs' own, so a read again can give it right. Its symbols are in the
        // sector it starts in and the next 2.
        var reread = 0
        for _ in 0..<3 where !damaged.isEmpty {
            try stop?.check()
            _ = try? drive.readSubchannelPW(at: away(from: range.lowerBound, in: toc), count: 1)
            var still = [Int]()
            for i in damaged {
                let first = range.lowerBound + i / 4
                guard first + 3 <= end, let read = try? drive.readSubchannelPW(at: first, count: 3),
                    read.count == 3 * 96, qFrames(read, from: first).misplaced.isEmpty
                else {
                    still.append(i)
                    continue
                }
                var pack = CDGraphics.packs(read)[i % 4]
                if CDGraphics.check(&pack) == .uncorrectable {
                    still.append(i)
                } else {
                    packs[i] = pack
                    reread += 1
                }
            }
            damaged = still
        }
        // A pack still damaged is left out (zeros), so that no player draws it.
        for i in damaged { packs[i] = [UInt8](repeating: 0, count: 24) }

        // By the rule of the look before the rip, so that a damaged pack is not taken for graphics.
        let graphics = CDGraphics.holds(packs, command: 9, instructions: CDGraphics.instructions)
        let extended = CDGraphics.holds(packs, command: 10, instructions: CDGraphics.extendedInstructions)
        guard graphics || extended else { return nil }
        try Data(packs.joined()).write(to: url, options: .atomic)
        return RipReport.Graphics(
            file: url.lastPathComponent, extended: extended ? true : nil,
            correctedPacks: corrected, rereadPacks: reread > 0 ? reread : nil, uncorrectablePacks: damaged.count,
            unreadableSectors: unreadable.isEmpty ? nil : unreadable,
            misplacedReads: misplacedReads > 0 ? misplacedReads : nil)
    }

    /// The Q frames of a raw P–W read: how many are valid, and the sectors whose valid frame
    /// names another sector, so that the drive gave another place's subchannel. A damaged Q
    /// frame (about 1 in 100) tells nothing.
    static func qFrames(_ pw: [UInt8], from first: Int) -> (valid: Int, misplaced: [Int]) {
        var valid = 0
        var misplaced = [Int]()
        for sector in 0..<(pw.count / 96) {
            var q = [UInt8](repeating: 0, count: QSubchannel.byteCount)
            for i in 0..<96 where pw[sector * 96 + i] & 0x40 != 0 { q[i / 8] |= 0x80 >> (i % 8) }
            let frame = QSubchannel(bytes: q)
            guard frame.isValid else { continue }
            valid += 1
            if let position = frame.position, position.lba != first + sector { misplaced.append(first + sector) }
        }
        return (valid, misplaced)
    }

    /// A sector far from `lba` in the disc's audio, for a read that moves the drive away.
    static func away(from lba: Int, in toc: TOC) -> Int {
        let areas = toc.audioAreas
        guard let first = areas.first, let last = areas.last else { return 0 }
        return lba - first.lowerBound > last.upperBound - lba ? first.lowerBound : last.upperBound - 1
    }
}
