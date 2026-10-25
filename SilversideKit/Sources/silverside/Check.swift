import ArgumentParser
import Foundation
import SilversideKit

struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Look earlier rips up in AccurateRip and CUETools DB again, for results that came since.",
        discussion: """
            A new release is often in neither database at first, and both fill in over weeks. check looks each rip \
            up again, with a new request, and checks its audio against what they have now: the rip's WAV files, or \
            the album's lossless files, which must still decode to the audio that was ripped. The disc is not \
            needed. The rip's report gets the new results; a match found before is never lost. A rip that CTDB now \
            has but does not verify can then be repaired with silverside repair.

            Examples:
              silverside check "<rip folder>"
              silverside check "~/Music/Silverside Library/Grateful Dead/Summer Magic 1985"
            """)

    @Argument(
        help: """
            Rip folders (with disc.json), album folders in the library (each disc's "Rip Report" in them), or \
            report files.
            """)
    var paths: [String]

    func run() async throws {
        var failed = 0
        for path in paths {
            let url = URL(filePath: (path as NSString).expandingTildeInPath)
            let reports = Self.reports(at: url)
            if reports.isEmpty { print("\(path): no rip report here.") }
            for file in reports {
                let name = file.lastPathComponent == "disc.json" ? file.deletingLastPathComponent().path : file.path
                print("\(name):")
                var check = RipCheck(reportAt: file)
                check.log = { print("  \($0)") }
                do {
                    let result = try await check.run()
                    print("  \(result.summary)")
                } catch {
                    print("  Could not be checked: \(error)")
                    failed += 1
                }
            }
        }
        if failed > 0 { throw ExitCode.failure }
    }

    /// A report file itself, a rip folder's disc.json, or an album folder's "Rip Report" files.
    static func reports(at url: URL) -> [URL] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [url] }
        let disc = url.appending(path: "disc.json")
        if manager.fileExists(atPath: disc.path) { return [disc] }
        let names = (try? manager.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { $0.hasPrefix("Rip Report") && $0.hasSuffix(".json") }.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.map { url.appending(path: $0) }
    }
}
