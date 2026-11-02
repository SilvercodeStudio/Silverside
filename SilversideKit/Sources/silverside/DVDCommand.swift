import ArgumentParser
import Foundation
import SilversideDarwin
import SilversideKit

struct DVDCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dvd", abstract: "Inspect DVD-Audio and extract MLP stereo or surround to verified FLAC tracks.",
        subcommands: [DVDInfo.self, DVDRip.self])
}

struct DVDSource: ParsableArguments {
    @OptionGroup var device: DeviceOptions
    @Option(help: "An unprotected DVD-Audio ISO or DVD directory, instead of a drive.") var source: String?

    func path() throws -> String {
        if let source {
            guard device.device == nil else { throw ValidationError("Use --source or --device, not both.") }
            let path = URL(fileURLWithPath: (source as NSString).expandingTildeInPath).standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path) else {
                throw CommandError("DVD source does not exist: \(path)")
            }
            return path
        }
        if let name = device.device, name.wholeMatch(of: /(?:\/dev\/)?r?disk\d+/) != nil {
            return "/dev/r"
                + name.replacingOccurrences(of: "/dev/", with: "").replacingOccurrences(of: "rdisk", with: "disk")
        }
        let drives = OpticalDrive.all()
        let drive: OpticalDrive
        if device.device != nil {
            drive = try device.drive(in: drives)
        } else {
            let found = drives.filter { $0.otherDiscBSDName != nil }
            guard found.count == 1 else {
                throw CommandError("Select a DVD drive with --device (see silverside drives).")
            }
            drive = found[0]
        }
        guard let bsd = drive.otherDiscBSDName else {
            throw CommandError("The \(drive.name) has no mounted DVD. See silverside drives.")
        }
        return "/dev/r" + bsd
    }
}

struct DVDInfo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info", abstract: "List DVD-Audio programs, formats, and supported track layouts.")
    @OptionGroup var source: DVDSource
    @Flag(help: "Print the versioned inventory as JSON.") var json = false

    func run() async throws {
        let input = try source.path()
        let tools = try DVDTools()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(
            "silverside-dvd-info-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let stop = StopToken()
        let interrupt = Interrupt(stop: stop, message: "Stopping DVD inspection…")
        defer { withExtendedLifetime(interrupt) {} }
        let inventory = try tools.inventory(source: input, work: work, stop: stop)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(inventory), as: UTF8.self))
            return
        }
        print("\(inventory.volume.isEmpty ? "DVD-Audio" : inventory.volume) — \(input)")
        for p in inventory.presentations {
            let format =
                p.format.map { "\($0.codec.uppercased()), \($0.sampleRate) Hz, \($0.bits)-bit, \($0.layout)" }
                ?? "format unknown"
            print(
                "  \(p.id): \(p.tracks.count) tracks, \(String(format: "%.1f", Double(p.durationPTS) / 90000)) seconds; \(format)\(p.authoredStereo ? "; authored stereo substream" : "")\(p.shortProgram ? "; short program (explicit --title required)" : "")"
            )
            if let reason = p.unsupportedReason { print("    Unsupported: \(reason)") }
        }
        print("Use dvd rip --mix surround|stereo|both, or --title SET:TITLE. Optional disc text is not yet parsed.")
    }
}

struct DVDRip: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rip", abstract: "Extract DVD-Audio to per-track FLAC files and a rip report.")
    @OptionGroup var source: DVDSource
    @Option(name: .shortAndLong, help: "A new output folder; its parent must already exist.") var output: String
    @Option(help: "auto (prefer surround), surround, stereo, or both. Ambiguous programs require --title.") var mix =
        "auto"
    @Option(help: "One explicit program from dvd info, such as 1:2. Cannot combine with --mix.") var title: String?

    func validate() throws {
        guard ["auto", "surround", "stereo", "both"].contains(mix) else {
            throw ValidationError("--mix must be auto, surround, stereo, or both.")
        }
        guard title == nil || mix == "auto" else { throw ValidationError("Use --title or --mix, not both.") }
    }
    func run() async throws {
        try Disclaimer.require()
        let input = try source.path()
        let tools = try DVDTools()
        let destination = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        let stop = StopToken()
        let interrupt = Interrupt(stop: stop, message: "Stopping DVD extraction; retaining the incomplete report…")
        defer { withExtendedLifetime(interrupt) {} }
        do {
            let report = try DVDExtraction.rip(
                source: input, output: destination, tools: tools, mix: mix, title: title, stop: stop
            ) { print($0) }
            print("Extracted \(report.programs.reduce(0) { $0 + $1.tracks.count }) tracks to \(destination.path)")
        } catch is CancellationError { throw ExitCode(130) }
    }
}
