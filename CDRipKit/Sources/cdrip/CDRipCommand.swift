import ArgumentParser
import Foundation

@main
struct CDRipCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cdrip",
        abstract: "Rip audio CDs with AccurateRip verification.",
        subcommands: [Drives.self, Info.self, Metadata.self, Rip.self, Repair.self]
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
