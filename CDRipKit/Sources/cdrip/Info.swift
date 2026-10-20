import ArgumentParser
import CDRipDarwin
import CDRipKit
import Foundation

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show a disc's table of contents, pregaps, codes, and disc IDs.")

    @OptionGroup var deviceOptions: DeviceOptions

    @Flag(help: "Do not look up the disc in AccurateRip and CTDB.")
    var offline = false

    func run() async throws {
        let drive = try IOKitDrive(bsdName: deviceOptions.bsdName())
        let toc = try drive.readTOC()

        print("Track  Start LBA  Length    Pregap    ISRC          Type")
        for track in toc.tracks {
            let isrc = track.kind == .audio ? try drive.readISRC(track: track.number) : nil
            let length = toc.sectorRange(of: track).count
            var notes = [track.kind == .audio ? "audio" : "data"]
            let pregap: String
            do {
                pregap = try PregapFinder.pregap(of: track, in: toc, drive: drive).map(Self.duration) ?? "-"
            } catch let error as PregapError {
                pregap = "?"
                notes.append(error.description)
            }
            if track.hasPreEmphasis { notes.append("pre-emphasis") }
            if track.isCopyPermitted { notes.append("copy permitted") }
            if track.session > 1 { notes.append("session \(track.session)") }
            if track.number == toc.tracks[0].number && track.startLBA > 0 { notes.append("audio before track 1?") }
            print(
                String(format: "%5d  %9d  ", track.number, track.startLBA) + Self.duration(length) + "  "
                    + pregap.padding(toLength: 8, withPad: " ", startingAt: 0) + "  "
                    + (isrc ?? "-").padding(toLength: 12, withPad: " ", startingAt: 0) + "  "
                    + notes.joined(separator: ", "))
        }
        print(String(format: "Lead  %10d  ", toc.leadOutLBA) + Self.duration(toc.leadOutLBA))
        print()
        print("MCN (barcode)        \(try drive.readMCN() ?? "-")")
        print("MusicBrainz disc ID  \(toc.musicBrainzDiscID)")
        print("freedb disc ID       \(String(format: "%08x", toc.freedbDiscID))")
        print("AccurateRip          \(toc.accurateRipDiscID.databaseURL)")
        print("CTDB TOC             \(toc.ctdbTOCString)")

        guard !offline else { return }
        print()
        let records = try await AccurateRipRecord.download(for: toc.accurateRipDiscID)
        if records.isEmpty {
            print("AccurateRip          not in the database")
        } else {
            let most = records.flatMap(\.tracks).map(\.confidence).max() ?? 0
            print("AccurateRip          \(records.count) records, up to \(most) submissions for a track")
        }
        let entries = try await CTDBEntry.lookup(toc)
        if entries.isEmpty {
            print("CTDB                 not in the database")
        } else {
            let most = entries.map(\.confidence).max() ?? 0
            let parity = entries.contains(where: \.hasParity) ? ", with repair data" : ""
            print("CTDB                 \(entries.count) entries, up to \(most) submissions\(parity)")
        }
    }

    /// Formats a sector count as MM:SS:FF (minutes, seconds, and frames of 1/75 second), as CUE sheets do.
    static func duration(_ sectors: Int) -> String {
        let seconds = sectors / CDDA.sectorsPerSecond
        return String(format: "%02d:%02d:%02d", seconds / 60, seconds % 60, sectors % CDDA.sectorsPerSecond)
    }
}
