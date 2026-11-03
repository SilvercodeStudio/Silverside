import Foundation

/// How much a drive slows down when a read takes the Q subchannel with the audio. The MATSHITA
/// and the ASUS read at the same speed with Q; the HL-DT-ST GUC0N and the PLDS DS8A5SH read
/// at less than half the speed (2026-11-03: 6.5× and 3.0×). The rip's first read takes Q from
/// some chunks only on such a drive (`TrackRipper.qEvery(forReadCost:)`).
public enum QReadCost {
    /// How many times as long a read with Q takes as one without: the same number of sectors in
    /// the middle of the disc's longest audio area, with Q between two reads without (the
    /// faster of them counts, as a drive can still be speeding up). About 2 seconds on a slow
    /// drive. Nil if a read fails or the drive gives no valid Q frame.
    public static func measure(drive: any CDDrive, toc: TOC, sectors: Int = 144, chunk: Int = 24) -> Double? {
        guard let area = toc.audioAreas.max(by: { $0.count < $1.count }), area.count >= 3 * sectors + 2 * chunk
        else { return nil }
        let start = area.lowerBound + (area.count - 3 * sectors) / 2
        func timed(_ first: Int, q: Bool) -> (seconds: Double, validQ: Int)? {
            let clock = ContinuousClock()
            var valid = 0
            let elapsed = clock.measure {
                for lba in stride(from: first, to: first + sectors, by: chunk) {
                    guard let read = try? drive.readAudioSectors(at: lba, count: chunk, c2: false, q: q) else {
                        valid = -1
                        return
                    }
                    valid += read.q.filter(\.isValid).count
                }
            }
            guard valid >= 0 else { return nil }
            return (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18, valid)
        }
        // The read before spins the drive up and moves it there.
        guard (try? drive.readAudioSectors(at: start - chunk, count: chunk)) != nil,
            let before = timed(start, q: false),
            let withQ = timed(start + sectors, q: true), withQ.validQ > 0,
            let after = timed(start + 2 * sectors, q: false)
        else { return nil }
        let without = min(before.seconds, after.seconds)
        // Less than 0.1 seconds more is no cost worth saving, and a fast read's times are noise
        // (a simulated drive's, or a busy computer's). The GUC0N takes 0.35 seconds more.
        guard without > 0, withQ.seconds - without >= 0.1 else { return 1 }
        return withQ.seconds / without
    }
}
