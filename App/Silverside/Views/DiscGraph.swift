import SilversideKit
import SwiftUI

/// The whole rip by position: each track to scale, the sectors that had trouble as bars (a
/// bar's height is the share of its column's sectors that are marked), and the read under
/// way. The same view shows a rip as it runs and an earlier rip's report.
struct DiscGraph: View {
    struct Track: Identifiable {
        var number: Int
        var sectors: Int
        /// Sectors with a C2 error.
        var flagged: Set<Int> = []
        var unreadable: Set<Int> = []
        /// Sectors that reads disagreed on, and were re-read.
        var suspect: Set<Int> = []
        /// Suspect sectors that the re-reads never settled.
        var unresolved: Set<Int> = []
        /// The track is proved right after all (by AccurateRip or CTDB), so its unresolved sectors were fixed.
        var isVerified = false
        /// How much of the track is read: 0 queued, 1 done.
        var readFraction = 0.0
        var isSkipped = false
        var id: Int { number }

        var hasTrouble: Bool { !(flagged.isEmpty && unreadable.isEmpty && suspect.isEmpty && unresolved.isEmpty) }

        /// "12 sectors re-read, 2 never agreed, C2 in 5 sectors", for the hover text.
        var troubleText: String {
            var parts = [String]()
            if !suspect.isEmpty { parts.append(Format.count(suspect.count, "sector") + " re-read") }
            if !unresolved.isEmpty {
                parts.append("\(unresolved.count) " + (isVerified ? "fixed by CTDB" : "never agreed"))
            }
            if !flagged.isEmpty { parts.append("C2 in " + Format.count(flagged.count, "sector")) }
            if !unreadable.isEmpty { parts.append(Format.count(unreadable.count, "sector") + " unreadable") }
            return parts.isEmpty ? "no trouble" : parts.joined(separator: ", ")
        }
    }

    var tracks: [Track]
    /// The read under way: the track, and the sector it is at.
    var cursor: (track: Int, sector: Int)?
    @State private var hoveredTrack: Int?

    private let gap = 2.0
    private let height = 34.0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                Canvas { context, size in draw(in: &context, size: size) }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hoveredTrack = track(at: point.x, width: geometry.size.width)
                        case .ended: hoveredTrack = nil
                        }
                    }
            }
            .frame(height: height)
            HStack(spacing: 12) {
                legend("Flagged by the drive", Theme.warning.opacity(0.55))
                legend("Re-read, then agreed", Theme.warning)
                legend("Fixed by CTDB", Theme.fixed)
                legend("Never agreed, or unreadable", Theme.bad)
                Spacer()
                Text(hoverText).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }

    private var hoverText: String {
        guard let number = hoveredTrack, let track = tracks.first(where: { $0.number == number }) else { return "" }
        return "Track \(number) · \(Format.duration(sectors: track.sectors)) · \(track.troubleText)"
    }

    /// Each track's place along the width, to scale.
    private func frames(width: Double, height: Double) -> [(track: Track, frame: CGRect)] {
        let total = tracks.reduce(0) { $0 + max($1.sectors, 0) }
        guard total > 0, !tracks.isEmpty else { return [] }
        let usable = max(0, width - gap * Double(tracks.count - 1))
        var x = 0.0
        var result = [(Track, CGRect)]()
        for track in tracks {
            let trackWidth = usable * Double(track.sectors) / Double(total)
            result.append((track, CGRect(x: x, y: 0, width: trackWidth, height: height)))
            x += trackWidth + gap
        }
        return result
    }

    private func track(at x: Double, width: Double) -> Int? {
        frames(width: width, height: height).first { $0.frame.minX <= x && x < $0.frame.maxX + gap }?.track.number
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let placed = frames(width: size.width, height: size.height)
        for (track, frame) in placed {
            context.fill(
                Path(roundedRect: frame, cornerRadius: 2),
                with: .color(Color.secondary.opacity(track.isSkipped ? 0.04 : 0.1)))
            if track.readFraction > 0 {
                var done = frame
                done.size.width = frame.width * min(1, track.readFraction)
                context.fill(Path(roundedRect: done, cornerRadius: 2), with: .color(Theme.sheenColors[1].opacity(0.3)))
            }
            guard track.hasTrouble, frame.width >= 1, track.sectors > 0 else { continue }
            // One column for each point of width; a column's bar shows how many of its sectors are marked.
            let columns = Int(frame.width.rounded(.down))
            let perColumn = Double(track.sectors) / Double(columns)
            var counts = Array(repeating: (flagged: 0, suspect: 0, fixed: 0, bad: 0), count: columns)
            func column(of sector: Int) -> Int? {
                guard sector >= 0, sector < track.sectors else { return nil }
                return min(columns - 1, Int(Double(sector) / perColumn))
            }
            for sector in track.flagged { if let column = column(of: sector) { counts[column].flagged += 1 } }
            for sector in track.suspect where !track.unresolved.contains(sector) {
                if let column = column(of: sector) { counts[column].suspect += 1 }
            }
            for sector in track.unresolved {
                if let column = column(of: sector) {
                    if track.isVerified { counts[column].fixed += 1 } else { counts[column].bad += 1 }
                }
            }
            for sector in track.unreadable { if let column = column(of: sector) { counts[column].bad += 1 } }
            for (index, count) in counts.enumerated() {
                let total = count.flagged + count.suspect + count.fixed + count.bad
                guard total > 0 else { continue }
                let share = min(1, Double(total) / perColumn)
                let barHeight = max(3, frame.height * (0.25 + 0.75 * share))
                let color: Color =
                    count.bad > 0
                    ? Theme.bad
                    : count.fixed > 0 ? Theme.fixed : count.suspect > 0 ? Theme.warning : Theme.warning.opacity(0.55)
                let bar = CGRect(x: frame.minX + Double(index), y: frame.maxY - barHeight, width: 1, height: barHeight)
                context.fill(Path(bar), with: .color(color))
            }
        }
        if let cursor, let (track, frame) = placed.first(where: { $0.track.number == cursor.track }), track.sectors > 0
        {
            let fraction = min(1, max(0, Double(cursor.sector) / Double(track.sectors)))
            let x = frame.minX + frame.width * fraction
            context.fill(
                Path(CGRect(x: x - 0.75, y: frame.minY, width: 1.5, height: frame.height)), with: .color(.primary))
        }
    }

    /// The graph of an earlier rip, from its report.
    static func tracks(of report: RipReport) -> [Track] {
        report.tracks.map { track in
            var row = Track(number: track.number, sectors: track.sectors)
            row.flagged = Set(track.c2Sectors ?? [])
            row.unreadable = Set(track.unreadableSectors ?? [])
            row.suspect = Set(track.suspectSectors)
            row.unresolved = Set(track.unresolvedSectors)
            let verdict = TrackVerdict(track, ctdb: report.ctdb)
            row.isVerified = verdict == .verified || verdict == .repaired
            row.readFraction = 1
            return row
        }
    }
}
