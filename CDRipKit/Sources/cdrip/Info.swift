import ArgumentParser
import CDRipDarwin
import CDRipKit
import Foundation

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show a disc's table of contents and disc IDs.")

    @Option(name: .shortAndLong, help: "The disc's BSD name, such as disk14 (see `drutil status`).")
    var device: String

    func run() throws {
        let toc = try IOKitDrive(bsdName: device).readTOC()

        print("Track  Start LBA  Length     Type")
        for track in toc.tracks {
            let length = toc.sectorRange(of: track).count
            var notes = [track.kind == .audio ? "audio" : "data"]
            if track.hasPreEmphasis { notes.append("pre-emphasis") }
            if track.isCopyPermitted { notes.append("copy permitted") }
            if track.session > 1 { notes.append("session \(track.session)") }
            print(
                String(format: "%5d  %9d  ", track.number, track.startLBA) + Self.duration(length) + "  "
                    + notes.joined(separator: ", "))
        }
        print(String(format: "Lead  %10d  ", toc.leadOutLBA) + Self.duration(toc.leadOutLBA))
        print()
        print("MusicBrainz disc ID  \(toc.musicBrainzDiscID)")
        print("freedb disc ID       \(String(format: "%08x", toc.freedbDiscID))")
        print("AccurateRip          \(toc.accurateRipDiscID.databaseURL)")
        print("CTDB TOC             \(toc.ctdbTOCString)")
    }

    /// Formats a sector count as MM:SS.FF (minutes, seconds, frames).
    static func duration(_ sectors: Int) -> String {
        let seconds = sectors / CDDA.sectorsPerSecond
        return String(format: "%02d:%02d.%02d", seconds / 60, seconds % 60, sectors % CDDA.sectorsPerSecond)
    }
}
