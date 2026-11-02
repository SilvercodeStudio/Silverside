import Foundation

public struct DVDError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Versioned helper protocol. DVD timestamps are 90 kHz ticks, not CD sectors.
public struct DVDInventory: Codable, Sendable {
    public var protocolVersion = 1
    public var source: String
    public var volume: String
    public var fingerprint: String
    public var libraryPath: String
    public var presentations: [DVDPresentation]

    public init(
        source: String, volume: String, fingerprint: String, libraryPath: String,
        presentations: [DVDPresentation]
    ) {
        self.source = source
        self.volume = volume
        self.fingerprint = fingerprint
        self.libraryPath = libraryPath
        self.presentations = presentations
    }
}

public struct DVDTrack: Codable, Sendable, Equatable {
    public var number: Int
    public var startPTS: Int64
    public var durationPTS: Int64
    public var firstSector: Int
    public var lastSector: Int

    public func frames(at rate: Int) throws -> Int64 {
        guard rate > 0, rate <= 192_000, durationPTS > 0,
            durationPTS <= Int64.max / Int64(rate), durationPTS * Int64(rate) % 90_000 == 0
        else {
            throw DVDError("Track \(number)'s duration does not resolve to whole samples at \(rate) Hz.")
        }
        return durationPTS * Int64(rate) / 90_000
    }
}

public struct DVDPresentation: Codable, Sendable {
    public var titleSet: Int
    public var title: Int
    public var indexByte: Int
    public var durationPTS: Int64
    public var tracks: [DVDTrack]
    /// The first implementation accepts only this bounded, one-cell-per-track layout.
    public var unsupportedReason: String?
    public var format: DVDAudioFormat?
    public var authoredStereo = false
    public var id: String { "\(titleSet):\(title)" }
    public var shortProgram: Bool { tracks.count == 1 && durationPTS <= 90_000 }
    public var sampleFile: String { "ats\(titleSet)-title\(title).aob" }

    public var resetsDecoder: Bool {
        tracks.count > 1 && tracks.allSatisfy { $0.startPTS == tracks[0].startPTS }
    }
}

public struct DVDAudioFormat: Codable, Sendable, Equatable {
    public var codec: String
    public var sampleRate: Int
    public var bits: Int
    public var channels: Int
    public var layout: String
}

/// An original, bounds-checked reader of the common on-disc ATS tables. It uses no
/// libdvdread in-memory structures. Unsupported navigation is retained for `dvd info`.
public enum DVDNavigation {
    public static func titleSetCount(manager: Data) throws -> Int {
        let b = Bytes(manager)
        guard try b.signature() == "DVDAUDIO-AMG" else { throw DVDError("This source has no DVD-Audio manager.") }
        let count = try b.number(63, 1)
        guard (1...99).contains(count) else { throw DVDError("Invalid DVD-Audio title-set count.") }
        return count
    }

    public static func presentations(ifo: Data, titleSet: Int, audioSectors: Int) throws -> [DVDPresentation] {
        let b = Bytes(ifo)
        guard try b.signature() == "DVDAUDIO-ATS", audioSectors > 0 else { throw DVDError("Invalid audio title set.") }
        let table = try b.number(204, 4) * 2048
        guard table >= 2048 else { throw DVDError("Invalid ATS table offset.") }
        let count = try b.number(table, 2)
        let end = try table + b.number(table + 4, 4) + 1
        guard (1...255).contains(count), end <= ifo.count, table + 8 + count * 8 <= end else {
            throw DVDError("Truncated or oversized ATS title table.")
        }
        let offsets = try (0..<count).map { try table + b.number(table + 8 + $0 * 8 + 4, 4) }
        var results = [DVDPresentation]()
        for index in 0..<count {
            let entry = table + 8 + index * 8
            let record = offsets[index]
            let recordEnd = offsets.filter { $0 > record }.min() ?? end
            guard record >= table + 8 + count * 8, record + 16 <= recordEnd, recordEnd <= end else {
                throw DVDError("Invalid ATS record offset.")
            }
            let trackCount = try b.number(record + 2, 1)
            let cellCount = try b.number(record + 3, 1)
            let duration = try b.number(record + 4, 4)
            let trackOffset = try b.number(record + 10, 2)
            let cellOffset = try b.number(record + 12, 2)
            var presentation = DVDPresentation(
                titleSet: titleSet, title: index + 1,
                indexByte: try b.number(entry, 1), durationPTS: Int64(duration), tracks: [])
            guard trackCount > 0, trackCount == cellCount, trackOffset == 16,
                cellOffset == 16 + trackCount * 20
            else {
                presentation.unsupportedReason = "Only the common one-audio-cell-per-track layout is supported yet."
                results.append(presentation)
                continue
            }
            guard record + cellOffset + cellCount * 12 <= recordEnd else {
                throw DVDError("Truncated or overlapping ATS cells.")
            }
            var total: Int64 = 0
            for number in 0..<trackCount {
                let t = record + 16 + number * 20
                let c = record + cellOffset + number * 12
                guard try b.number(t + 4, 1) == number + 1, try b.number(c + 1, 1) == 0 else {
                    presentation.unsupportedReason = "This program has an unsupported cell mapping or cell type."
                    break
                }
                let first = try b.number(c + 4, 4)
                let last = try b.number(c + 8, 4)
                guard first <= last, last < audioSectors, last < Int32.max else {
                    throw DVDError("ATS cell lies outside the audio files.")
                }
                let track = DVDTrack(
                    number: number + 1, startPTS: Int64(try b.number(t + 6, 4)),
                    durationPTS: Int64(try b.number(t + 10, 4)), firstSector: first, lastSector: last)
                guard track.durationPTS > 0 else { throw DVDError("Zero-length DVD-Audio track.") }
                if let previous = presentation.tracks.last, previous.lastSector + 1 != first {
                    presentation.unsupportedReason = "Noncontiguous or overlapping audio cells are not supported yet."
                }
                presentation.tracks.append(track)
                total += track.durationPTS
            }
            if presentation.unsupportedReason == nil {
                guard total == Int64(duration) else {
                    throw DVDError("ATS track durations do not sum to the program length.")
                }
                var next = presentation.tracks[0].startPTS
                let continuous = presentation.tracks.allSatisfy { track in
                    defer { next += track.durationPTS }
                    return track.startPTS == next
                }
                if !continuous && !presentation.resetsDecoder {
                    presentation.unsupportedReason = "Mixed timestamp discontinuities are not supported yet."
                }
            }
            results.append(presentation)
        }
        return results
    }

    struct Bytes {
        let data: [UInt8]
        init(_ data: Data) { self.data = Array(data) }
        func number(_ offset: Int, _ length: Int) throws -> Int {
            guard offset >= 0, length > 0, offset <= data.count - length else {
                throw DVDError("Truncated DVD navigation.")
            }
            return data[offset..<offset + length].reduce(0) { $0 * 256 + Int($1) }
        }
        func signature() throws -> String {
            guard data.count >= 2048 else { throw DVDError("Truncated DVD information file.") }
            return String(decoding: data.prefix(12), as: UTF8.self)
        }
    }
}
