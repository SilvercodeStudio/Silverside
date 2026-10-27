import Foundation

/// A report on one drive, for a bug report: what the drive is, how it is connected, what
/// Silverside knows of it, and how it behaves in quick checks with a disc in it. It holds no
/// audio and no serial numbers. From it, a drive that the developer does not have can be
/// modeled in `SimulatedDrive`.
public struct DriveReport: Codable, Sendable {
    public struct Check: Codable, Equatable, Sendable {
        public var name: String
        /// True if the drive did what Silverside asks of it.
        public var passed: Bool
        /// What happened, for people to read.
        public var result: String
        public var milliseconds: Int
    }

    public var program = SilversideVersion.program
    public var date = Date()
    public var macOS = ProcessInfo.processInfo.operatingSystemVersionString
    /// The Mac's model identifier, such as "Mac14,13".
    public var mac: String
    /// The drive's IOKit registry: device and protocol characteristics, and the USB bridge's.
    public var registry: [String: String]
    public var profile: DriveProfile?
    /// The disc in the drive: its CTDB TOC and disc ID. No audio.
    public var disc: [String: String] = [:]
    public var checks: [Check] = []

    public init(registry: [String: String], profile: DriveProfile?) {
        self.registry = registry
        self.profile = profile
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        mac = String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Runs the checks with the disc in `drive`. Each one is short; together they take about
    /// 20 seconds. The disc should be clean, because the checks read near its start and end.
    public mutating func check(_ drive: any CDDrive, progress: (String) -> Void = { _ in }) {
        func run(_ name: String, _ body: () throws -> (Bool, String)) {
            progress(name)
            let clock = ContinuousClock()
            var outcome = (false, "")
            let time = clock.measure {
                do { outcome = try body() } catch { outcome = (false, "error: \(error)") }
            }
            let milliseconds = Int(time.components.seconds * 1000 + time.components.attoseconds / 1_000_000_000_000_000)
            checks.append(Check(name: name, passed: outcome.0, result: outcome.1, milliseconds: milliseconds))
        }

        var toc: TOC?
        run("Read the TOC") {
            toc = try drive.readTOC()
            let data = toc!.tracks.count - toc!.audioTracks.count
            return (true, "\(toc!.audioTracks.count) audio tracks, \(data) data tracks, lead-out at \(toc!.leadOutLBA)")
        }
        guard let toc, let first = toc.audioTracks.first, let last = toc.audioTracks.last else { return }
        disc = ["toc": toc.ctdbTOCString, "musicBrainzDiscID": toc.musicBrainzDiscID]
        let middle = (first.startLBA + toc.sectorRange(of: last).upperBound) / 2

        run("Read 2,600 sectors from the middle") {
            let start = ContinuousClock.now
            for lba in stride(from: middle, to: middle + 2600, by: 26) {
                _ = try drive.readAudioSectors(at: lba, count: 26)
            }
            let seconds =
                Double((ContinuousClock.now - start).components.attoseconds) / 1e18
                + Double((ContinuousClock.now - start).components.seconds)
            // 75 sectors a second is 1×.
            return (true, String(format: "%.1f× (%.1f s)", 2600 / 75 / max(seconds, 0.001), seconds))
        }
        run("C2 error flags") {
            let read = try drive.readAudioSectorsWithC2(at: middle, count: 26)
            let flagged = stride(from: 0, to: read.errorFlags.count, by: CDDA.errorFlagBytesPerSector).filter {
                read.errorFlags[$0..<($0 + CDDA.errorFlagBytesPerSector)].contains { $0 != 0 }
            }.count
            return (
                read.errorFlags.count == 26 * CDDA.errorFlagBytesPerSector, "given; \(flagged) of 26 sectors flagged"
            )
        }
        run("Q subchannel, 100 sectors") {
            let frames = try drive.readQSubchannel(at: first.startLBA + 100, count: 100)
            let valid = frames.filter(\.isValid).count
            return (valid > 0, "\(valid) of \(frames.count) frames valid")
        }
        run("Read past the lead-out (overread)") {
            do {
                _ = try drive.readAudioSectors(at: toc.leadOutLBA, count: 1)
                return (true, "reads past the lead-out")
            } catch {
                return (true, "does not read past the lead-out (\(error))")
            }
        }
        run("CD-Text") {
            let text = try drive.readCDText().flatMap(CDText.init(bytes:))
            return (
                true, text.map { "\($0.titles.count) titles, \($0.performers.count) performers" } ?? "none on this disc"
            )
        }
        run("Cache size") {
            let sectors = try CacheProbe(drive: drive).cacheSectors(toc: toc)
            return (true, sectors.map { "\($0) sectors or fewer (32 is the precision)" } ?? "no size found")
        }
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
