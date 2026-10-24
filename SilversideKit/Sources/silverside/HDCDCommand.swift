import ArgumentParser
import Foundation
import SilversideKit

struct HDCDCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hdcd",
        abstract: "Look for HDCD codes in audio files: rips, or albums in a library.",
        discussion: """
            HDCD hides control codes in the lowest bit of the audio. Many discs with the HDCD logo have codes that \
            ask for nothing, and an HDCD decoder plays them as they are; others ask for peak extend or a gain \
            adjustment, which a decoder applies. silverside rip looks for the codes in each track by itself; this \
            command looks in files from before, in any lossless format (WAV, AIFF, FLAC, or Apple Lossless). A \
            lossy file has no codes left.

            Examples:
              silverside hdcd "~/Music/Silverside Library/Grateful Dead/Cornell 5-8-77"
              silverside hdcd "Track 01.wav" "Track 02.wav"
            """)

    @Argument(help: "Audio files, or folders to look through, with the folders in them.")
    var paths: [String]

    static let extensions: Set<String> = ["wav", "aif", "aiff", "flac", "m4a"]

    func run() throws {
        var found = 0
        var changing = 0
        var scanned = 0
        for path in paths {
            let url = URL(filePath: (path as NSString).expandingTildeInPath)
            for file in Self.files(at: url) {
                let name =
                    file.path.hasPrefix(url.path + "/") ? String(file.path.dropFirst(url.path.count + 1)) : file.path
                do {
                    let codes = try HDCDCodes.scan(fileAt: file)
                    scanned += 1
                    if let codes {
                        found += 1
                        if codes.changesAudio { changing += 1 }
                    }
                    print("\(name): \(Self.describe(codes))")
                } catch {
                    print("\(name): could not be read (\(error))")
                }
            }
        }
        print()
        print(
            (scanned == 1 ? "1 file" : "\(scanned) files") + ": \(found) with HDCD codes"
                + (found > 0 ? ", \(changing) of them with codes that change the audio." : "."))
    }

    static func describe(_ codes: HDCDCodes?) -> String {
        guard let codes else { return "no HDCD codes" }
        var text = "HDCD codes (\(codes.packets)), asking for \(codes.featuresText)"
        if codes.transientFilter { text += ", transient filter" }
        if codes.errors > 0 { text += ", \(codes.errors) damaged" }
        return text
    }

    /// The audio files at `url`: the file itself, or those in the folder and below, sorted by path.
    static func files(at url: URL) -> [URL] {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            print("\(url.path): not found")
            return []
        }
        guard isFolder.boolValue else { return [url] }
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return (enumerator?.allObjects as? [URL] ?? [])
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
