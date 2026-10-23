import Foundation

extension RipReport {
    /// The report as Markdown, for people to read. disc.json has the same facts, for programs.
    public var markdown: String {
        let toc = try? TOC(ctdbTOCString: self.toc)
        let medium = toc.flatMap { release?.medium(for: $0) }
        var lines = [String]()
        let disc =
            medium.map { release!.media.count > 1 ? ", disc \($0.position) of \(release!.media.count)" : "" } ?? ""
        lines.append("# Rip report: " + (release.map { "\($0.artist) - \($0.title)" } ?? "unknown release") + disc)
        lines.append("")
        lines.append(
            "\(program), \(ISO8601DateFormatter().string(from: date)). \(secure ? "Secure rip" : "Single pass").")
        lines.append("")

        lines.append("## Result")
        lines.append("")
        let accurate = tracks.filter { $0.accurateRip == .accurate }.count
        let otherPressings = tracks.filter { $0.accurateRip == .otherPressings }.count
        var result = "\(accurate) of \(tracks.count) tracks are accurate in AccurateRip"
        if otherPressings > 0 { result += ", and \(otherPressings) match other pressings (free of errors)" }
        lines.append(result + ".")
        lines.append("")
        lines.append("CTDB: " + ctdbSummary + ".")
        let repaired = tracks.reduce(0) { $0 + $1.repairedSamples }
        if repaired > 0 { lines += ["", "\(repaired) samples were repaired with CTDB's repair data."] }
        lines.append("")

        lines.append("## Tracks")
        lines.append("")
        lines.append(
            "| Track | Title | Length | Pregap | AccurateRip | CTDB | Reads | Suspect | C2 | Unreadable | Repaired | ISRC |"
        )
        lines.append("|---:|---|---:|---:|---|---:|---:|---:|---:|---:|---:|---|")
        for track in tracks {
            let title = medium.flatMap { medium in
                toc?.audioTracks.firstIndex { $0.number == track.number }.flatMap {
                    medium.tracks.indices.contains($0) ? medium.tracks[$0].title : nil
                }
            }
            let accurateRip: String =
                switch track.accurateRip {
                case .accurate:
                    "accurate" + (track.accurateRipConfidence.map { " (v1 \($0[0]), v2 \($0[1]))" } ?? "")
                case .otherPressings: "other pressings"
                case .notInDatabase: "not in database"
                case .notAccurate: "**not accurate**"
                }
            let unresolved = track.unresolvedSectors.count
            var cells = [String]()
            cells.append(String(track.number))
            cells.append(Self.escaped(title ?? "") + (track.preEmphasis ? " (pre-emphasis)" : ""))
            cells.append(Self.time(track.sectors))
            cells.append(track.pregapSectors.map(Self.time) ?? "")
            cells.append(accurateRip)
            cells.append(track.ctdbConfidence.map { $0 > 0 ? String($0) : "no match" } ?? "")
            cells.append(
                track.rereadRounds > 0 ? "\(track.fullReads) + \(track.rereadRounds) rounds" : String(track.fullReads))
            let suspect = track.suspectSectors.isEmpty ? "" : String(track.suspectSectors.count)
            cells.append(suspect + (unresolved > 0 ? " (\(unresolved) unresolved)" : ""))
            cells.append(track.c2Sectors.map { $0.isEmpty ? "" : String($0.count) } ?? "not read")
            cells.append(track.unreadableSectors.map { $0.isEmpty ? "" : String($0.count) } ?? "")
            cells.append(track.repairedSamples > 0 ? String(track.repairedSamples) : "")
            cells.append(track.isrc ?? "")
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        lines.append("")
        lines.append(
            "Reads: whole reads of the track, then rounds of re-reads of its suspect sectors. Suspect, C2, and"
                + " unreadable: sectors. Repaired: samples.")
        lines.append("")

        let problems = tracks.filter { !$0.unresolvedSectors.isEmpty || $0.shiftedReads?.isEmpty == false }
        if !problems.isEmpty {
            lines.append("## Problems")
            lines.append("")
            let repaired = ctdb.status == .repaired || ctdb.status == .partlyRepaired
            for track in problems {
                if !track.unresolvedSectors.isEmpty {
                    let runs = Self.runs(track.unresolvedSectors)
                    var line =
                        "- Track \(track.number): \(track.unresolvedSectors.count) \(track.unresolvedSectors.count == 1 ? "sector" : "sectors") read differently each time"
                        + (runs.count > 1
                            ? ", in \(runs.count) runs (\(runs.first!) to \(runs.last!))" : " (\(runs[0]))")
                    if let unreadable = track.unreadableSectors, !unreadable.isEmpty {
                        line += "; \(unreadable.count) could not be read at all"
                    }
                    line += repaired && track.repairedSamples > 0 ? ". CTDB's repair fixed them." : "."
                    lines.append(line)
                    lines.append("  <details><summary>Every sector</summary>")
                    lines.append("")
                    lines.append("  \(Self.list(track.unresolvedSectors))")
                    lines.append("")
                    lines.append("  </details>")
                }
                if let shifts = track.shiftedReads, !shifts.isEmpty {
                    lines.append(
                        "- Track \(track.number): \(shifts.count) reads lost their place"
                            + " (\(shifts.map { $0 > 0 ? "+\($0)" : "\($0)" }.joined(separator: ", ")) samples) and were left out."
                    )
                }
            }
            lines.append("")
        }

        if let encoding {
            lines.append("## Encoding")
            lines.append("")
            var summary = "\(encoding.format.name), by \(encoding.encoder)"
            if let settings = encoding.settingsText { summary += " (\(settings))" }
            lines.append(summary + ", \(ISO8601DateFormatter().string(from: encoding.date)). " + encoding.checkText)
            lines.append("")
            lines.append("Folder: `\((encoding.folder as NSString).abbreviatingWithTildeInPath)`")
            lines.append("")
            lines.append("| Track | File |")
            lines.append("|---:|---|")
            for file in encoding.files { lines.append("| \(file.track) | \(Self.escaped(file.file)) |") }
            lines.append("")
        }

        lines.append("## Disc")
        lines.append("")
        lines.append("| | |")
        lines.append("|---|---|")
        if let release, !release.isManual {
            lines.append(
                "| MusicBrainz release | [\(Self.escaped(release.title))](https://musicbrainz.org/release/\(release.id)) |"
            )
        } else if release != nil {
            lines.append("| MusicBrainz release | none; the names were typed in or came from CD-Text |")
        }
        lines.append("| MusicBrainz disc ID | \(musicBrainzDiscID) |")
        lines.append("| freedb disc ID | \(freedbDiscID) |")
        lines.append("| AccurateRip disc ID | \(accurateRipDiscID) |")
        lines.append("| CTDB TOC | \(self.toc) |")
        if let mcn { lines.append("| MCN (barcode) | \(mcn) |") }
        if let cdText {
            let disc = [cdText.performers[0], cdText.titles[0]].compactMap { $0 }.joined(separator: " - ")
            lines.append("| CD-Text | \(Self.escaped(disc.isEmpty ? "tracks only" : disc)) |")
        }
        lines.append("")

        lines.append("## Drive")
        lines.append("")
        let offset = drive.readOffset > 0 ? "+\(drive.readOffset)" : "\(drive.readOffset)"
        lines.append(
            "\(drive.vendor) \(drive.product), firmware \(drive.revision). Read offset \(offset) samples"
                + " (\(drive.offsetSource)).")
        return lines.joined(separator: "\n") + "\n"
    }

    var ctdbSummary: String {
        let entry = ctdb.entry.map { "entry \($0)" + (ctdb.confidence.map { " (\($0) submissions)" } ?? "") } ?? ""
        let shift = ctdb.shift.map { $0 == 0 ? "" : " at shift \($0 > 0 ? "+" : "")\($0)" } ?? ""
        switch ctdb.status {
        case .verified: return "verified with \(entry)\(shift)"
        case .repaired: return "repaired with \(entry)\(shift)"
        case .partlyRepaired: return "partly repaired with \(entry)\(shift)"
        case .notVerified: return "no entry verifies or repairs the rip"
        case .notInDatabase: return "the disc is not in the database"
        case .notChecked: return "not checked"
        }
    }

    /// A length in sectors as "M:SS.FF" (frames of 1/75 s).
    static func time(_ sectors: Int) -> String {
        String(format: "%d:%02d.%02d", sectors / 4500, sectors / 75 % 60, sectors % 75)
    }

    /// Sector numbers, with runs as "40-52".
    /// The sectors as runs: "9336", "13597-13598".
    static func runs(_ sectors: [Int]) -> [String] {
        DiscRepairer.ranges(of: sectors.sorted()).map {
            $0.count == 1 ? String($0.lowerBound) : "\($0.lowerBound)-\($0.upperBound - 1)"
        }
    }

    static func list(_ sectors: [Int]) -> String {
        DiscRepairer.ranges(of: sectors.sorted()).map {
            $0.count == 1 ? String($0.lowerBound) : "\($0.lowerBound)-\($0.upperBound - 1)"
        }.joined(separator: ", ")
    }

    /// Text that cannot break a Markdown table.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }
}
