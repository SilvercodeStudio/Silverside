import ArgumentParser
import CDRipDarwin

struct Drives: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the optical drives and their discs.")

    func run() throws {
        let drives = OpticalDrive.all()
        if drives.isEmpty {
            print("No optical drives found.")
        }
        for drive in drives {
            let name = [drive.vendor, drive.product].filter { !$0.isEmpty }.joined(separator: " ")
            let connection = [drive.location, drive.interconnect].filter { !$0.isEmpty }.joined(separator: " ")
            print("\(name) (firmware \(drive.revision), \(connection))")
            print("  " + (drive.discBSDName.map { "CD: \($0)" } ?? "No CD"))
        }
    }
}
