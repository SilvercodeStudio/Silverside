import ArgumentParser
import SilversideDarwin

/// The `--device` option. Without it, commands use the only drive that has a CD.
struct DeviceOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "The disc's BSD name, such as disk14 (see `silverside drives`).")
    var device: String?

    /// The disc to use: `--device`, else the one drive with a CD. With several, the message
    /// names them and the way out: `--device`, and `--all` for a command that has it.
    func bsdName(orAll: Bool = false) throws -> String {
        if let device { return device }
        let names = OpticalDrive.all().compactMap(\.discBSDName)
        switch names.count {
        case 0: throw CommandError("No drive has an audio CD.")
        case 1: return names[0]
        default:
            throw CommandError(
                "More than one drive has a CD (\(names.joined(separator: ", "))). Use --device"
                    + (orAll ? ", or --all for every drive." : "."))
        }
    }
}

/// An error with a message for the user. ArgumentParser prints it without the usage text
/// that it adds to a `ValidationError`, because the command line itself was correct.
struct CommandError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
