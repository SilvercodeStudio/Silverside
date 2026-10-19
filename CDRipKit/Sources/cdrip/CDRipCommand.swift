import ArgumentParser

@main
struct CDRipCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cdrip",
        abstract: "Rip audio CDs with AccurateRip verification.",
        subcommands: [Info.self]
    )
}
