import ArgumentParser
import Foundation
import SilversideKit

@main
struct SilversideCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "silverside",
        abstract: "Rip audio CDs securely, verify and repair them, and encode them into a tagged library.",
        discussion: """
            silverside reads each track with the drive's offset corrected, and checks it against AccurateRip and \
            CUETools DB (CTDB). Tracks that do not match are read again where the reads disagree, and repaired \
            with CTDB's repair data. MusicBrainz names the rip and tags the encoded files.

            Quick start:
              silverside drives                      the drives, and the disc in each
              silverside rip                         rip the only disc in a drive
              silverside rip -d disk14 --encode      rip, then encode into the library
              silverside encode -i <rip folder>      encode a rip later
              silverside config                      the settings (library, format, names)

            Silverside is for archival copies of discs that you own, for your personal use. The first \
            rip asks you to agree to this; silverside --accept-disclaimer agrees ahead of time.
            """,
        version: SilversideVersion.described,
        subcommands: [
            Drives.self, Info.self, CDTextCommand.self, Rip.self, Repair.self, Check.self, Metadata.self, Encode.self,
            HDCDCommand.self, VideoCommand.self,
            Config.self, Eject.self, License.self,
        ]
    )

    @Flag(help: "Agree to rip only discs that you own, for your personal use, at your own risk.")
    var acceptDisclaimer = false

    /// With no subcommand: the agreement, or the help.
    func run() async throws {
        guard acceptDisclaimer else {
            print(Self.helpMessage())
            return
        }
        try Disclaimer.accept()
    }

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
