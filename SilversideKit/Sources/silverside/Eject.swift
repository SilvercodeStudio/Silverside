import ArgumentParser
import SilversideDarwin

struct Eject: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Eject the disc from a drive.",
        discussion: """
            Unmounts the disc (macOS mounts each audio CD) and ejects it, as the Finder does. Named by \
            its drive, a disc that macOS never recognized (so it has no BSD name) is ejected through \
            Disc Recording, as `drutil eject` does; an empty drive opens its tray.

            Examples:
              silverside eject -d disk14
              silverside eject -d bu50n
              silverside eject --all
            """)

    @OptionGroup var deviceOptions: DeviceOptions

    @Flag(help: "Eject the disc from every drive that has one: CDs, DVDs, and Blu-ray discs.")
    var all = false

    func run() async throws {
        if deviceOptions.device != nil, !deviceOptions.namesADisc {
            let drive = try deviceOptions.drive()
            if let bsdName = drive.discBSDName ?? drive.otherDiscBSDName {
                try await DiscEject.eject(bsdName: bsdName)
                print("Ejected \(bsdName) from the \(drive.name).")
            } else if let path = drive.registryPath {
                switch try DiscEject.ejectDrive(registryPath: path, name: drive.name) {
                case .ejected: print("Ejected the disc from the \(drive.name).")
                case .trayOpened: print("Opened the \(drive.name)'s tray.")
                }
            } else {
                throw CommandError("Cannot find the \(drive.name) in the I/O Registry.")
            }
            return
        }
        guard all else {
            let name = try deviceOptions.bsdName(orAll: true)
            try await DiscEject.eject(bsdName: name)
            print("Ejected \(name).")
            return
        }
        // Every disc: CDs, and DVDs and Blu-ray discs too. One that fails does not stop the others.
        let drives = OpticalDrive.all()
        let names = OpticalDrive.shortNames(of: drives)
        var ejected = 0
        var failures = [String]()
        for (index, drive) in drives.enumerated() {
            guard let bsdName = drive.discBSDName ?? drive.otherDiscBSDName else {
                // A disc that macOS never recognized can hang the drive: only by name, on purpose.
                if let path = drive.registryPath, DiscEject.hasMedia(registryPath: path) == true {
                    print(
                        "The \(drive.name) has a disc that macOS did not recognize: "
                            + "silverside eject -d \(names[index]) ejects it.")
                }
                continue
            }
            do {
                try await DiscEject.eject(bsdName: bsdName)
                print("Ejected \(bsdName) from the \(drive.name).")
                ejected += 1
            } catch {
                failures.append("\(drive.name): \(error)")
            }
        }
        if !failures.isEmpty { throw CommandError(failures.joined(separator: "\n")) }
        if ejected == 0 { throw CommandError("No drive has a disc.") }
    }
}
