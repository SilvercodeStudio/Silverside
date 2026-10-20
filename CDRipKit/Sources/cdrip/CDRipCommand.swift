import ArgumentParser

@main
struct CDRipCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cdrip",
        abstract: "Rip audio CDs with AccurateRip verification.",
        subcommands: [Drives.self, Info.self]
    )
}
