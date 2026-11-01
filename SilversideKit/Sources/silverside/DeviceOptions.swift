import ArgumentParser
import SilversideDarwin

/// The `--device` option. Without it, commands use the only drive that has a CD.
struct DeviceOptions: ParsableArguments {
    @Option(
        name: .shortAndLong,
        help:
            "The drive, by its name in `silverside drives` (such as asus or bu50n), or its disc's BSD name (such as disk14)."
    )
    var device: String?

    /// True if `--device` gives a BSD name ("disk14", "/dev/rdisk14"), not a drive's name.
    var namesADisc: Bool {
        guard let device else { return false }
        return device.hasPrefix("/dev/") || device.wholeMatch(of: /disk\d+(s\d+)?/) != nil
    }

    /// The drive that `--device` names, among `drives`. Its name, or a part of it that only one
    /// drive's name has; with none or several, the message lists the names to use.
    func drive(in drives: [OpticalDrive] = OpticalDrive.all()) throws -> OpticalDrive {
        guard let device else { throw CommandError("Name the drive with --device.") }
        let found = OpticalDrive.indices(named: device, in: drives)
        guard found.count == 1 else {
            let names = OpticalDrive.shortNames(of: drives).enumerated()
                .map { "\($0.element) (\(drives[$0.offset].name))" }
            throw CommandError(
                (found.isEmpty ? "No drive is called \(device)." : "More than one drive's name has \(device).")
                    + (names.isEmpty
                        ? " No optical drive is connected." : " Use one of: \(names.joined(separator: ", ")).")
            )
        }
        return drives[found[0]]
    }

    /// The disc to use: the one `--device` names, or the one in the drive it names, else the one
    /// drive with a CD. With several, the message names them and the way out: `--device`, and
    /// `--all` for a command that has it.
    func bsdName(orAll: Bool = false) throws -> String {
        if let device, namesADisc { return device }
        let drives = OpticalDrive.all()
        if device != nil {
            let drive = try drive(in: drives)
            guard let bsdName = drive.discBSDName else {
                throw CommandError(
                    "The \(drive.name) has no audio CD" + (drive.otherDisc.map { " (it has a \($0.name))" } ?? "") + "."
                )
            }
            return bsdName
        }
        let names = drives.compactMap(\.discBSDName)
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
