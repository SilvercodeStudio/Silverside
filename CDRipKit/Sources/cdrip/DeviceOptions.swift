import ArgumentParser
import CDRipDarwin

/// The `--device` option. Without it, commands use the only drive that has a CD.
struct DeviceOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "The disc's BSD name, such as disk14 (see `cdrip drives`).")
    var device: String?

    func bsdName() throws -> String {
        if let device { return device }
        let names = OpticalDrive.all().compactMap(\.discBSDName)
        switch names.count {
        case 0: throw ValidationError("No drive has an audio CD.")
        case 1: return names[0]
        default: throw ValidationError("More than one drive has a CD (\(names.joined(separator: ", "))). Use --device.")
        }
    }
}
