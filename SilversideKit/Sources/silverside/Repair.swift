import ArgumentParser
import Foundation
import SilversideDarwin
import SilversideKit

struct Repair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check ripped WAV files against CUETools DB, and repair them with its repair data.",
        discussion: """
            silverside rip already repairs a disc that it can. Use repair to pool rips of the same disc from several \
            drives (one -i for each), or to try again with the disc in a drive, which can re-read the samples of \
            columns that cannot be repaired. Each rip's saved suspect samples (Track NN.suspects) join the pool. \
            With no disc in a drive, the TOC comes from the first folder's disc.json.

            Examples:
              silverside repair -d disk16 -i "<rip on this drive>" -i "<rip on another drive>"
              silverside repair -i "<rip folder>"
            """)

    @OptionGroup var deviceOptions: DeviceOptions

    @Option(
        help: """
            The disc's CTDB TOC, such as 0:31400:58160:295575. Default: from disc.json in the first input folder, \
            else from the disc in the drive.
            """)
    var toc: String?

    @Option(
        name: .shortAndLong,
        help: """
            A folder with ripped "Track NN.wav" files. Give it more than once to pool several rips of the disc: \
            sectors where they disagree are suspect, and help the repair.
            """)
    var input: [String]

    @Option(
        name: .shortAndLong, help: "The folder for repaired files. Default: the input folder's name with \" repaired\"."
    )
    var output: String?

    @Option(
        help:
            "With the disc in a drive, read each track that does not match AccurateRip until it has this many versions."
    )
    var reads = 3

    @Option(help: "Rounds of re-reads for columns that cannot be repaired, when the disc is in a drive.")
    var rereadRounds = 4

    @Option(help: "The drive's read offset for re-reads. Default: from the drive's profile.")
    var offset: Int?

    func run() async throws {
        guard let firstInput = input.first else { throw ValidationError("Give at least one --input folder.") }
        let firstFolder = URL(filePath: firstInput, directoryHint: .isDirectory).standardizedFileURL
        // The TOC: from --toc, from the rip's disc.json, or from the disc. With the disc
        // in a drive (by --device, or with no other TOC), re-reads are possible.
        let savedTOC = RipPool.savedTOC(in: firstFolder)
        let usesDrive = deviceOptions.device != nil || (self.toc == nil && savedTOC == nil)
        let driveTOC = usesDrive ? try IOKitDrive(bsdName: deviceOptions.bsdName()).readTOC() : nil
        guard let toc = try (self.toc ?? savedTOC).map({ try TOC(ctdbTOCString: $0) }) ?? driveTOC else {
            throw CommandError("The disc's TOC is not known.")
        }
        if let driveTOC, driveTOC.ctdbTOCString != toc.ctdbTOCString {
            throw CommandError("The disc in the drive is not the disc of the rip (TOC \(driveTOC.ctdbTOCString)).")
        }

        var repair = RipRepair(toc: toc, folders: input.map { URL(filePath: $0, directoryHint: .isDirectory) })
        if let output { repair.output = URL(filePath: output, directoryHint: .isDirectory) }
        if usesDrive { (repair.reader, repair.cacheFlushSectors) = try rereader(toc: toc) }
        repair.reads = reads
        repair.rereadRounds = rereadRounds
        repair.events = Self.print
        // Ctrl-C stops the repair after the read under way.
        let interrupt = Interrupt(
            stop: repair.stop, message: "Stopping after the read under way. Press Ctrl-C again to stop at once.")
        defer { withExtendedLifetime(interrupt) {} }
        do {
            _ = try await repair.run()
        } catch is CancellationError {
            Swift.print("Stopped. Nothing was written to \(repair.output.path).")
            throw ExitCode(130)
        }
    }

    /// An offset-corrected reader for the disc in the drive, with the drive's offset, and
    /// the number of sectors that flush the drive's cache.
    private func rereader(toc: TOC) throws -> (reader: AudioReader, cacheFlushSectors: Int) {
        let bsdName = try deviceOptions.bsdName()
        let drive = try IOKitDrive(bsdName: bsdName)
        let profile = try OpticalDrive.all().first(where: { $0.discBSDName == bsdName }).map {
            try DriveProfileStore().profile(vendor: $0.vendor, product: $0.product, revision: $0.revision)
        }
        guard let readOffset = offset ?? profile?.offset?.value else {
            throw CommandError("The drive's read offset is not known. Give it with --offset.")
        }
        var reader = AudioReader(drive: drive, toc: toc, readOffset: readOffset, canOverread: false)
        reader.unreadableRetries = 3
        return (reader, profile?.cacheFlushSectors ?? 4000)
    }

    private static func print(_ event: RipRepairEvent) {
        switch event {
        case .trackAccurate(let number):
            Swift.print(String(format: "Track %2d  accurate in AccurateRip", number))
        case .trackMatchesOtherPressing(let number, let shift):
            Swift.print(
                String(format: "Track %2d  free of errors: matches another pressing at ", number)
                    + shift.signedDescription)
        case .trackPooled(let number, let versions, let suspectSamples):
            Swift.print(
                String(format: "Track %2d  ", number)
                    + "\(versions) versions, \(suspectSamples) samples where they disagree")
        case .poolFileSkipped(let file):
            Swift.print("\(file.url.path) was not used: \(file.reason).")
        case .ctdbEntries(let count, let mostSubmissions):
            Swift.print("CTDB: \(count) entries, up to \(mostSubmissions) submissions")
        case .repairLog(let line):
            Swift.print(line)
        case .finished(let result):
            let withoutRepairData =
                result.entriesWithoutRepairData == 0
                ? ""
                : "\(result.entriesWithoutRepairData) more entries match the rip's alignment, but have no repair data."
            switch result.outcome {
            case .verified(let entry, let shift):
                Swift.print(
                    "Verified: the rip matches entry \(entry.id) (\(entry.confidence) submissions)"
                        + (shift == 0 ? "" : " at shift \(shift.signedDescription)") + ", with no errors.")
            case .repaired:
                break
            case .partlyRepaired(_, _, let tracks, _):
                if !withoutRepairData.isEmpty { Swift.print(withoutRepairData) }
                Swift.print("No entry repairs the whole disc. Keeping the corrections in tracks \(tracks),")
                Swift.print("whose CTDB track CRCs then match.")
            case .notVerified:
                if !withoutRepairData.isEmpty { Swift.print(withoutRepairData) }
                Swift.print("Could not verify or repair the rip with any entry.")
            }
        case .writing(let folder, let repairedSamples):
            Swift.print("  Repaired \(repairedSamples) samples. Files: \(folder.path)")
        case .trackWritten(let number, let repairedSamples, let accurateRip):
            var line = String(format: "  Track %2d  %6d samples repaired  ", number, repairedSamples)
            switch accurateRip {
            case .accurate(let v1, let v2): line += "AccurateRip: accurate (v1 \(v1), v2 \(v2))"
            case .notAccurate: line += "AccurateRip: not accurate"
            case .notChecked: line += "AccurateRip: not in the database"
            }
            Swift.print(line)
        case .reportWritten(let folder):
            Swift.print("  Report: \(folder.appending(path: "disc.json").path)")
        }
    }
}
