import ArgumentParser
import CDRipDarwin
import CDRipKit

struct Drives: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the optical drives, their discs, and their read offsets.")

    @OptionGroup var deviceOptions: DeviceOptions

    @Option(help: "Set the read offset, in samples, of the drive that holds the disc. It overrides all other sources.")
    var setOffset: Int?

    @Flag(help: "Remove the offset that --set-offset set.")
    var clearOffset = false

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
            print("  " + (drive.discBSDName.map { "CD: \($0)" } ?? "No CD"))
            let profile = store.profile(vendor: drive.vendor, product: drive.product, revision: drive.revision)
            if let (offset, source) = profile.offset {
                print("  Read offset: \(Rip.signed(offset)) (\(Rip.describe(source)))")
            } else {
                print("  Read offset: not known (cdrip rip looks it up in AccurateRip's drive list)")
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
