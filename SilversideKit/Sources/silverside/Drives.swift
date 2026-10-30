import ArgumentParser
import Foundation
import SilversideDarwin
import SilversideKit

struct Drives: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the optical drives, their discs, and their read offsets.",
        discussion: """
            A drive's read offset comes from rips that confirm it (two or more discs that agree), from \
            AccurateRip's list of drives, or from --set-offset, which overrides both. --measure-cache times reads \
            to find how much the drive caches, so re-reads empty the cache with fewer reads.

            Examples:
              silverside drives
              silverside drives -d disk14 --set-offset 6
              silverside drives -d disk14 --measure-cache
            """)

    @OptionGroup var deviceOptions: DeviceOptions

    @Option(help: "Set the read offset, in samples, of the drive that holds the disc. It overrides all other sources.")
    var setOffset: Int?

    @Flag(help: "Remove the offset that --set-offset set.")
    var clearOffset = false

    @Flag(
        help: """
            Write a report on the drive that holds the disc, for a bug report: the drive, its connection, what \
            Silverside knows of it, and quick checks with the disc (about 20 seconds; use a clean disc). It has no audio.
            """)
    var report = false

    @Option(name: .shortAndLong, help: "The report's file. Default: \"Silverside Drive Report <drive>.json\" here.")
    var output: String?

    @Flag(
        help: """
            Measure the cache of the drive that holds the disc, from read times, and keep it in the drive's profile. \
            Use a clean disc: the test reads near its start and its end.
            """)
    var measureCache = false

    func validate() throws {
        if setOffset != nil && clearOffset { throw ValidationError("Use --set-offset or --clear-offset, not both.") }
    }

    func run() throws {
        let drives = OpticalDrive.all()
        var store = try DriveProfileStore()
        if report {
            let bsdName = try deviceOptions.bsdName()
            guard let drive = drives.first(where: { $0.discBSDName == bsdName }) else {
                throw CommandError("Cannot find the drive that holds \(bsdName).")
            }
            var report = DriveReport(
                registry: drive.registry,
                profile: store.profiles["\(drive.vendor) \(drive.product) \(drive.revision)"])
            print("Checking \(drive.vendor) \(drive.product) with the disc in it...")
            report.check(try IOKitDrive(bsdName: bsdName)) { print("  \($0)") }
            for check in report.checks {
                print(
                    String(
                        format: "  %@ %@: %@ (%d ms)", check.passed ? "ok  " : "FAIL", check.name, check.result,
                        check.milliseconds))
            }
            let name = NameTemplate.safeComponent("Silverside Drive Report \(drive.vendor) \(drive.product)") + ".json"
            let url = URL(filePath: output ?? name)
            try report.write(to: url)
            print("Report: \(url.path)")
            return
        }
        if setOffset != nil || clearOffset || measureCache {
            let bsdName = try deviceOptions.bsdName()
            guard let drive = drives.first(where: { $0.discBSDName == bsdName }) else {
                throw CommandError("Cannot find the drive that holds \(bsdName).")
            }
            var profile = store.profile(vendor: drive.vendor, product: drive.product, revision: drive.revision)
            if setOffset != nil || clearOffset { profile.manualOffset = setOffset }
            if measureCache {
                let device = try IOKitDrive(bsdName: bsdName)
                print("Measuring the cache of \(drive.vendor) \(drive.product)...")
                guard let sectors = try CacheProbe(drive: device).cacheSectors(toc: device.readTOC()) else {
                    throw CommandError("No cache size found: reads stayed fast, or the disc is too short.")
                }
                profile.cacheSectors = sectors
            }
            try store.save(profile)
        }

        if drives.isEmpty {
            print("No optical drives found.")
        }
        for drive in drives {
            let name = [drive.vendor, drive.product].filter { !$0.isEmpty }.joined(separator: " ")
            let connection = [drive.location, drive.interconnect].filter { !$0.isEmpty }.joined(separator: " ")
            print("\(name) (firmware \(drive.revision), \(connection))")
            if let bsdName = drive.discBSDName {
                // macOS already has the TOC, so this does not spin the disc.
                if let toc = try? IOKitDrive(bsdName: bsdName).readTOC() {
                    let seconds =
                        toc.audioTracks.reduce(0) { $0 + toc.sectorRange(of: $1).count } / CDDA.sectorsPerSecond
                    let data = toc.tracks.count - toc.audioTracks.count
                    guard !toc.audioTracks.isEmpty else {
                        print("  CD: \(bsdName), a data disc (\(data) data track\(data == 1 ? "" : "s")), no audio")
                        continue
                    }
                    print(
                        "  CD: \(bsdName), \(toc.audioTracks.count) audio tracks, "
                            + String(format: "%d:%02d", seconds / 60, seconds % 60)
                            + (data > 0 ? ", and \(data) data track\(data == 1 ? "" : "s")" : ""))
                    // The release an earlier lookup found, from the cache: no request.
                    if let release = ReleaseLookup.cachedRelease(toc: toc) {
                        let disc = release.medium(for: toc).flatMap {
                            release.media.count > 1 ? " (disc \($0.position) of \(release.media.count))" : nil
                        }
                        print("  \(release.artist) - \(release.title)" + (disc ?? ""))
                    }
                } else {
                    print("  CD: \(bsdName) (its TOC cannot be read)")
                }
            } else if let other = drive.otherDisc, let bsdName = drive.otherDiscBSDName {
                print("  \(other.name): \(bsdName), not a CD")
            } else {
                print("  No CD")
            }
            let profile = store.profile(vendor: drive.vendor, product: drive.product, revision: drive.revision)
            if let (offset, source) = profile.offset {
                print("  Read offset: \(offset.signedDescription) (\(source.description))")
            } else {
                print("  Read offset: not known (silverside rip looks it up in AccurateRip's drive list)")
            }
            if let sectors = profile.cacheSectors {
                let megabytes = Double(sectors * CDDA.bytesPerSector) / 1_048_576
                print(
                    sectors <= CacheProbe(timedRead: { _, _ in .zero }).precision
                        ? "  Cache: keeps only the latest read (\(sectors) sectors or fewer)"
                        : String(format: "  Cache: about %d sectors (%.1f MB)", sectors, megabytes))
                print("  Cache flush before re-reads: \(profile.cacheFlushSectors) sectors")
            }
        }
    }
}
