import ArgumentParser
import SilversideDarwin

struct Eject: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Eject the disc from a drive.",
        discussion: """
            Unmounts the disc (macOS mounts each audio CD) and ejects it, as the Finder does.

            Examples:
              silverside eject -d disk14
              silverside eject --all
            """)

    @OptionGroup var deviceOptions: DeviceOptions

    @Flag(help: "Eject the disc from every drive that has one.")
    var all = false

    func run() async throws {
        let names =
            all ? OpticalDrive.all().compactMap(\.discBSDName) : [try deviceOptions.bsdName(orAll: true)]
        if names.isEmpty { throw CommandError("No drive has a CD.") }
        for name in names {
            try await DiscEject.eject(bsdName: name)
            print("Ejected \(name).")
        }
    }
}
