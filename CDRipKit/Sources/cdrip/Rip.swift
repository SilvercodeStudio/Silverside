import ArgumentParser
import CDRipDarwin
import CDRipKit
import Foundation

struct Rip: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rip audio tracks to WAV files and check them against AccurateRip.")

    @OptionGroup var deviceOptions: DeviceOptions

    @Option(help: "The drive's read offset in samples, for this rip only.")
    var offset: Int?

    @Option(help: "The tracks to rip, such as 1,3-5. Default: all audio tracks.")
    var tracks: String?

    @Option(name: .shortAndLong, help: "The folder for the WAV files. Default: \"CDRip <MusicBrainz disc ID>\".")
    var output: String?

    @Flag(help: "Do not look up AccurateRip or its drive offset list.")
    var offline = false

    func run() async throws {
        let bsdName = try deviceOptions.bsdName()
        let drive = try IOKitDrive(bsdName: bsdName)
        let toc = try drive.readTOC()
        let selected = try Self.tracks(tracks, of: toc)

        // The drive's profile gives the offset, unless --offset does.
        guard let device = OpticalDrive.all().first(where: { $0.discBSDName == bsdName }) else {
            throw CommandError("Cannot find the drive that holds \(bsdName).")
        }
        let driveName = "\(device.vendor) \(device.product)"
        var store = try DriveProfileStore()
        var profile = store.profile(vendor: device.vendor, product: device.product, revision: device.revision)
        if profile.listedOffset == nil && !offline {
            profile.listedOffset = try await DriveOffsetList.download().entry(
                vendor: device.vendor, product: device.product)?.offset
            try store.save(profile)
        }
        let readOffset: Int
        let source: String
        if let offset {
            (readOffset, source) = (offset, "from --offset")
        } else if let (value, profileSource) = profile.offset {
            (readOffset, source) = (value, Self.describe(profileSource))
        } else {
            throw CommandError("The read offset of \(driveName) is not known. Give it with --offset.")
        }
        print("Drive: \(driveName) (firmware \(device.revision)), read offset \(Self.signed(readOffset)) \(source)")

        let records = offline ? [] : try await AccurateRipRecord.download(for: toc.accurateRipDiscID)
        print(
            "AccurateRip: "
                + (offline
                    ? "not checked (--offline)"
                    : records.isEmpty ? "disc not in the database" : "\(records.count) records"))

        let folder = URL(filePath: output ?? "CDRip \(toc.musicBrainzDiscID)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        print("Folder: \(folder.path)")
        print()

        let reader = AudioReader(drive: drive, toc: toc, readOffset: readOffset, canOverread: false)
        let ripper = TrackRipper(reader: reader, records: records)
        var discOffsets = Set<Int>()
        var accurateCount = 0
        for track in selected {
            let start = ContinuousClock.now
            let rip = try ripper.rip(track)
            try WAVFile.write(rip.samples, to: folder.appending(path: String(format: "Track %02d.wav", track.number)))
            let seconds = (ContinuousClock.now - start).components.seconds
            discOffsets.formUnion(rip.matchingOffsets)

            var result: String
            switch rip.verification {
            case .accurate(let v1, let v2):
                accurateCount += 1
                result = "accurate (v1 \(v1), v2 \(v2) submissions)"
            case .notAccurate:
                let others = rip.matchingOffsets.map(Self.signed).joined(separator: ", ")
                result = "NOT accurate" + (others.isEmpty ? "" : " (matches at offsets \(others))")
            case .notChecked:
                result = "not checked"
            }
            if track.hasPreEmphasis { result += ", pre-emphasis" }
            let length = toc.sectorRange(of: track).count
            print(String(format: "Track %2d  %@  %3d s  ", track.number, Info.duration(length), seconds) + result)
        }

        print()
        if !records.isEmpty {
            print("\(accurateCount) of \(selected.count) tracks are accurate.")
            if !discOffsets.isEmpty {
                profile.record(disc: toc.accurateRipDiscID.name, offsets: Array(discOffsets))
                try store.save(profile)
                print(
                    "This disc matches AccurateRip at offsets \(discOffsets.sorted().map(Self.signed).joined(separator: ", "))."
                )
            }
            if !discOffsets.isEmpty && !discOffsets.contains(readOffset) {
                print(
                    "It does not match at the offset used. Either this pressing is not in AccurateRip, or the offset is wrong."
                )
            }
        }
        if let confirmed = profile.confirmedOffset {
            print("Rips of \(profile.observations.count) discs confirm this drive's offset: \(Self.signed(confirmed)).")
        } else {
            print("This drive's offset is not yet confirmed by rips of two or more discs.")
        }
    }

    /// The audio tracks that a list such as "1,3-5" names, or all audio tracks.
    static func tracks(_ list: String?, of toc: TOC) throws -> [TOC.Track] {
        guard let list else { return toc.audioTracks }
        var numbers = Set<Int>()
        for part in list.split(separator: ",") {
            let bounds = part.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let first = bounds.first ?? nil, bounds.count <= 2, let last = bounds.last ?? nil, first <= last
            else {
                throw ValidationError("Cannot read the track list \"\(list)\".")
            }
            numbers.formUnion(first...last)
        }
        let tracks = toc.audioTracks.filter { numbers.contains($0.number) }
        guard tracks.count == numbers.count else {
            throw ValidationError("The disc has no audio track for some of \(list).")
        }
        return tracks
    }

    static func describe(_ source: DriveProfile.OffsetSource) -> String {
        switch source {
        case .manual: "(set by hand)"
        case .confirmed: "(confirmed by rips)"
        case .accurateRipList: "(from AccurateRip's drive list)"
        }
    }

    static func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }
}
