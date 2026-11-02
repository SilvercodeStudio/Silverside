import Darwin
import Foundation
import SilversideKit

@main
struct DVDHelper {
    static func main() {
        // Keep library diagnostics out of the JSON protocol, even if a library logs to stdout.
        let protocolOutput = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        unsetenv("DVDCSS_VERBOSE")
        setenv("DVDCSS_CACHE", "off", 1)
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let operation = args.first else { throw DVDError("Expected capabilities, inventory or read.") }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if operation == "capabilities", args.count == 1 {
                let library = try DVDLibrary()
                struct Capabilities: Encodable {
                    var protocolVersion = 1
                    var libraryPath: String
                    var operations = ["inventory", "read"]
                    var cppmAPI = true
                }
                protocolOutput.write(try encoder.encode(Capabilities(libraryPath: library.path)))
            } else if operation == "inventory", args.count == 3 {
                let inventory: DVDInventory
                if let directory = DVDDirectory(args[1]) {
                    inventory = try directory.inventory(source: args[1])
                    for p in inventory.presentations where p.unsupportedReason == nil {
                        guard let first = p.tracks.first else { continue }
                        try directory.copy(
                            title: p.titleSet, first: first.firstSector,
                            count: min(512, first.lastSector - first.firstSector + 1),
                            output: URL(fileURLWithPath: args[2]).appendingPathComponent(p.sampleFile).path)
                    }
                } else {
                    let library = try DVDLibrary()
                    inventory = try library.withDisc(args[1]) { disc in
                        let result = try library.inventory(disc, source: args[1])
                        for presentation in result.presentations where presentation.unsupportedReason == nil {
                            guard let first = presentation.tracks.first else { continue }
                            try library.copy(
                                disc, titleSet: presentation.titleSet, first: first.firstSector,
                                count: min(512, first.lastSector - first.firstSector + 1),
                                output: URL(fileURLWithPath: args[2]).appendingPathComponent(presentation.sampleFile)
                                    .path)
                        }
                        return result
                    }
                }
                protocolOutput.write(try encoder.encode(inventory))
            } else if operation == "read", args.count == 8,
                let title = Int(args[2]), let first = Int(args[3]), let count = Int(args[4])
            {
                guard (1...99).contains(title) else { throw DVDError("Invalid title set.") }
                if let directory = DVDDirectory(args[1]) {
                    let inventory = try directory.inventory(source: args[1])
                    guard inventory.fingerprint == args[6], args[7] == "protocol-1" else {
                        throw DVDError("The source navigation changed since inventory.")
                    }
                    try directory.copy(title: title, first: first, count: count, output: args[5])
                } else {
                    let library = try DVDLibrary()
                    try library.withDisc(args[1]) { disc in
                        let inventory = try library.inventory(disc, source: args[1])
                        guard inventory.fingerprint == args[6], args[7] == "protocol-1" else {
                            throw DVDError("The source navigation changed since inventory.")
                        }
                        try library.copy(disc, titleSet: title, first: first, count: count, output: args[5])
                    }
                }
                protocolOutput.write(Data("{\"protocolVersion\":1,\"complete\":true}\n".utf8))
            } else {
                throw DVDError("Invalid helper arguments.")
            }
        } catch {
            FileHandle.standardError.write(Data("DVD helper: \(error)\n".utf8))
            exit(1)
        }
    }
}
