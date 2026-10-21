import ArgumentParser
import CDRipDarwin
import CDRipKit
import Foundation

struct CDTextCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cdtext",
        abstract: "Show a disc's CD-Text: the titles and names that some discs carry for players.",
        discussion: """
            CD-Text can hold, for the disc and each track: a title, performer, songwriter, composer, arranger, \
            and message; and for the disc: a disc ID (the label's), a genre, and the UPC or EAN, with each \
            track's ISRC. A disc can carry it in up to 8 languages; cdrip reads the first (block 0). Few discs \
            have CD-Text at all.

            Examples:
              cdrip cdtext -d disk14
              cdrip cdtext -d disk14 --packs     the raw packs, as the drive gives them
              cdrip cdtext -d disk14 --json
            """)

    @OptionGroup var deviceOptions: DeviceOptions

    @Flag(help: "Show the raw 18-byte packs: type, track, sequence, block and position, and text.")
    var packs = false

    @Flag(help: "Print the CD-Text as JSON.")
    var json = false

    func run() throws {
        let drive = try IOKitDrive(bsdName: deviceOptions.bsdName())
        let toc = try drive.readTOC()
        guard let bytes = try drive.readCDText() else {
            print("This disc has no CD-Text.")
            return
        }
        if packs {
            print("Type  Track  Seq  Block/pos  Text          The same, in hex")
            for pack in CDText.packs(in: bytes) {
                let text = pack[4..<16].map { (0x20...0x7E).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
                let hex = pack[4..<16].map { String(format: "%02X", $0) }.joined(separator: " ")
                print(
                    String(
                        format: "0x%02X  %5d  %3d  %d/%-2d       %@  %@", pack[0], pack[1] & 0x7F, pack[2],
                        (pack[3] >> 4) & 7,
                        pack[3] & 0x0F, text, hex))
            }
            return
        }
        guard let text = CDText(bytes: bytes) else {
            print("The disc has CD-Text, but no pack of it could be read.")
            return
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(text), as: UTF8.self))
            return
        }
        let fields: [(String, [Int: String])] = [
            ("Title", text.titles), ("Performer", text.performers), ("Songwriter", text.songwriters),
            ("Composer", text.composers), ("Arranger", text.arrangers), ("Message", text.messages),
        ]
        print("Disc")
        for (name, values) in fields {
            if let value = values[0] { print("  \(name.padding(toLength: 12, withPad: " ", startingAt: 0))\(value)") }
        }
        if let id = text.discID { print("  Disc ID     \(id)") }
        if let genre = text.genre { print("  Genre       \(genre)") }
        if let code = text.codes[0] { print("  UPC/EAN     \(code)") }
        let languages = text.languages.sorted { $0.key < $1.key }.map { "block \($0.key): \($0.value)" }
        if !languages.isEmpty { print("  Languages   \(languages.joined(separator: ", "))") }
        if let set = text.characterSet { print("  Characters  \(set)") }
        for track in toc.audioTracks {
            let lines =
                fields.compactMap { name, values in values[track.number].map { (name, $0) } }
                + (text.codes[track.number].map { [("ISRC", $0)] } ?? [])
            guard !lines.isEmpty else { continue }
            print(String(format: "Track %d", track.number))
            for (name, value) in lines { print("  \(name.padding(toLength: 12, withPad: " ", startingAt: 0))\(value)") }
        }
    }
}
