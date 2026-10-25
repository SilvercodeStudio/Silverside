import ArgumentParser
import Foundation
import SilversideDarwin
import SilversideKit

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show a disc's table of contents, pregaps, codes, and disc IDs.",
        discussion: """
            Shows each track's start, length, pregap, and ISRC, the disc's MCN (barcode), its MusicBrainz, \
            freedb, AccurateRip, and CTDB IDs, and whether AccurateRip and CTDB have it. It does not ask MusicBrainz \
            (see silverside metadata).
            """)

    @OptionGroup var deviceOptions: DeviceOptions

    @Flag(help: "Do not look up the disc in AccurateRip and CTDB.")
    var offline = false

    func run() async throws {
        let drive = try IOKitDrive(bsdName: deviceOptions.bsdName())
        let toc = try drive.readTOC()

        print("Track  Start LBA  Length    Pregap    ISRC          Type")
        for track in toc.tracks {
            let isrc = track.kind == .audio ? try SubchannelCodes.isrc(of: track, in: toc, drive: drive) : nil
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
            if track == toc.tracks[0] && track.kind == .audio && track.startLBA > 0 {
                notes.append(try Self.describeStart(of: track, drive: drive, toc: toc))
            }
            print(
                String(format: "%5d  %9d  ", track.number, track.startLBA) + Self.duration(length) + "  "
                    + pregap.padding(toLength: 8, withPad: " ", startingAt: 0) + "  "
                    + (isrc ?? "-").padding(toLength: 12, withPad: " ", startingAt: 0) + "  "
                    + notes.joined(separator: ", "))
        }
        print(String(format: "Lead  %10d  ", toc.leadOutLBA) + Self.duration(toc.leadOutLBA))
        print()
        print("MCN (barcode)        \(try SubchannelCodes.mcn(in: toc, drive: drive) ?? "-")")
        print("Media                \(((try? drive.readMediaType()) ?? nil).map { "\($0)" } ?? "-")")
        if let text = (try? drive.readCDText()).flatMap({ $0.flatMap(CDText.init(bytes:)) }) {
            Self.printCDText(text, toc: toc)
        } else {
            print("CD-Text              -")
        }
        print("MusicBrainz disc ID  \(toc.musicBrainzDiscID)")
        print("freedb disc ID       \(String(format: "%08x", toc.freedbDiscID))")
        guard !toc.audioTracks.isEmpty else {
            print()
            print("This is a data disc, with no audio tracks to rip.")
            return
        }
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

    /// Says whether the sectors before track 1 are silent or hold audio, such as a hidden track.
    static func describeStart(of track: TOC.Track, drive: IOKitDrive, toc: TOC) throws -> String {
        let samples = try AudioReader(drive: drive, toc: toc, readOffset: 0, canOverread: false)
            .readSamples(0..<(track.startLBA * CDDA.samplesPerSector))
        // With no offset correction, the end can hold the start of track 1. Up to
        // 5 sectors covers the read offset of almost every drive.
        let checked = samples.dropLast(5 * CDDA.samplesPerSector)
        let sectors = "\(track.startLBA) sectors before track 1"
        if checked.isEmpty { return sectors }
        return checked.allSatisfy { $0 == 0 } ? "\(sectors) are silent" : "\(sectors) hold audio (hidden track?)"
    }

    /// Formats a sector count as MM:SS:FF (minutes, seconds, and frames of 1/75 second), as CUE sheets do.
    static func duration(_ sectors: Int) -> String {
        let seconds = sectors / CDDA.sectorsPerSecond
        return String(format: "%02d:%02d:%02d", seconds / 60, seconds % 60, sectors % CDDA.sectorsPerSecond)
    }

    static func printCDText(_ text: CDText, toc: TOC) {
        let disc = [text.performers[0], text.titles[0]].compactMap { $0 }.joined(separator: " - ")
        print("CD-Text              " + (disc.isEmpty ? "(tracks only)" : disc))
        for track in toc.audioTracks {
            let parts = [text.performers[track.number], text.titles[track.number]].compactMap { $0 }
            if !parts.isEmpty {
                print(String(format: "  %2d  ", track.number) + parts.joined(separator: " - "))
            }
        }
        if let code = text.codes[0] { print("  UPC/EAN  \(code)") }
        if let genre = text.genre { print("  Genre    \(genre)") }
        if let languages = text.languagesText { print("  Languages \(languages)") }
    }
}
