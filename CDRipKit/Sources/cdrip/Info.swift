import ArgumentParser
import CDRipDarwin
import CDRipKit
import Foundation

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show a disc's table of contents and disc IDs.")

    @OptionGroup var deviceOptions: DeviceOptions

    func run() throws {
        let drive = try IOKitDrive(bsdName: deviceOptions.bsdName())
        let toc = try drive.readTOC()

        print("Track  Start LBA  Length    ISRC          Type")
        for track in toc.tracks {
            let isrc = track.kind == .audio ? try drive.readISRC(track: track.number) : nil
            let length = toc.sectorRange(of: track).count
            var notes = [track.kind == .audio ? "audio" : "data"]
            if track.hasPreEmphasis { notes.append("pre-emphasis") }
            if track.isCopyPermitted { notes.append("copy permitted") }
            if track.session > 1 { notes.append("session \(track.session)") }
            print(
                String(format: "%5d  %9d  ", track.number, track.startLBA) + Self.duration(length) + "  "
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
    }

    /// Formats a sector count as MM:SS.FF (minutes, seconds, frames).
    static func duration(_ sectors: Int) -> String {
        let seconds = sectors / CDDA.sectorsPerSecond
        return String(format: "%02d:%02d.%02d", seconds / 60, seconds % 60, sectors % CDDA.sectorsPerSecond)
    }
}
