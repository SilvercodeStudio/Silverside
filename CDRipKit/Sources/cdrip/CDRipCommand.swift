import ArgumentParser
import CDRipKit
import Foundation

@main
struct CDRipCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cdrip",
        abstract: "Rip audio CDs securely, verify and repair them, and encode them into a tagged library.",
        discussion: """
            cdrip reads each track with the drive's offset corrected, and checks it against AccurateRip and \
            CUETools DB (CTDB). Tracks that do not match are read again where the reads disagree, and repaired \
            with CTDB's repair data. MusicBrainz names the rip and tags the encoded files.

            Quick start:
              cdrip drives                      the drives, and the disc in each
              cdrip rip                         rip the only disc in a drive
              cdrip rip -d disk14 --encode      rip, then encode into the library
              cdrip encode -i <rip folder>      encode a rip later
              cdrip config                      the settings (library, format, names)
            """,
        version: CDRipVersion.string,
        subcommands: [
            Drives.self, Info.self, CDTextCommand.self, Rip.self, Repair.self, Metadata.self, Encode.self, Config.self,
        ]
    )

    /// Prints each line at once, also when the output goes to a file or a pipe,
    /// so a long rip shows its progress.
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            var command = try parseAsRoot()
            if var command = command as? any AsyncParsableCommand {
                try await command.run()
            } else {
                try command.run()
            }
        } catch {
            exit(withError: error)
        }
    }
}
