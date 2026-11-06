import Foundation

public struct DVDError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Versioned helper protocol. DVD timestamps are 90 kHz ticks, not CD sectors.
public struct DVDInventory: Codable, Sendable {
    public var protocolVersion = 2
    public var source: String
    public var volume: String
    public var fingerprint: String
    public var libraryPath: String
    public var presentations: [DVDPresentation]
    /// Title sets that could not be inspected; never silently omitted.
    public var titleSetIssues: [DVDTitleSetIssue]?

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

public struct DVDTitleSetIssue: Codable, Sendable {
    public var titleSet: Int
    public var reason: String
    public init(titleSet: Int, reason: String) {
        self.titleSet = titleSet
        self.reason = reason
    }
}

public struct DVDTrackFormat: Codable, Sendable {
    public var number: Int
    public var format: DVDAudioFormat?
    public var unsupportedReason: String?
    public init(number: Int, format: DVDAudioFormat? = nil, unsupportedReason: String? = nil) {
        self.number = number
        self.format = format
        self.unsupportedReason = unsupportedReason
    }
}

public struct DVDVideoReference: Codable, Sendable, Equatable {
    public var titleSet: Int
    public var title: Int
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

/// Tracks whose timestamps advance continuously. A new run is a candidate for
/// a fresh decoder, not proof that decoding there is independent: extraction
/// must still check packet timestamps, decoder diagnostics, lengths and PCM.
public struct DVDDecodeRun: Sendable, Equatable {
    public var tracks: [DVDTrack]
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
    /// Bounded header/preview observations, not a complete decode of each track.
    public var trackFormats: [DVDTrackFormat]?
    public var videoReference: DVDVideoReference?
    public var authoredStereo = false
    public var id: String { "\(titleSet):\(title)" }
    public var shortProgram: Bool { tracks.count == 1 && durationPTS <= 90_000 }
    public func sampleFile(track: Int) -> String { "ats\(titleSet)-title\(title)-track\(track).aob" }

    public var resetsDecoder: Bool {
        guard let runs = try? decodingRuns() else { return false }
        return runs.count > 1 && runs.allSatisfy { $0.tracks.count == 1 }
    }

    /// Keep continuous tracks together; a repeated or backward track-start
    /// clock starts a new run. Forward gaps and partial overlaps remain unknown,
    /// rather than silently inserting silence or treating damaged timing as a reset.
    public func decodingRuns() throws -> [DVDDecodeRun] {
        guard !tracks.isEmpty else { throw DVDError("DVD program has no tracks.") }
        var runs = [DVDDecodeRun]()
        for track in tracks {
            guard track.startPTS >= 0, track.durationPTS > 0 else { throw DVDError("Invalid track timestamp.") }
            if let previous = runs.last?.tracks.last {
                let (expected, overflow) = previous.startPTS.addingReportingOverflow(previous.durationPTS)
                guard !overflow else { throw DVDError("Track timestamp overflow.") }
                if track.startPTS == expected {
                    runs[runs.count - 1].tracks.append(track)
                    continue
                }
                guard track.startPTS <= previous.startPTS else {
                    throw DVDError("Forward timestamp gaps or partial overlaps are not supported yet.")
                }
            }
            runs.append(DVDDecodeRun(tracks: [track]))
        }
        return runs
    }
}

public struct DVDAudioFormat: Codable, Sendable, Equatable, CustomStringConvertible {
    public var codec: String
    public var sampleRate: Int
    public var bits: Int
    public var channels: Int
    public var layout: String
    public var description: String { "\(codec.uppercased()), \(sampleRate) Hz, \(bits)-bit, \(layout)" }
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

    public static func presentations(
        ifo: Data, titleSet: Int, audioSectors: Int, videoReferences: [Int: DVDVideoReference] = [:]
    ) throws -> [DVDPresentation] {
        let b = Bytes(ifo)
        guard try b.signature() == "DVDAUDIO-ATS", audioSectors > 0 || !videoReferences.isEmpty else {
            throw DVDError("Invalid audio title set.")
        }
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
            presentation.videoReference = videoReferences[index + 1]
            if let video = presentation.videoReference {
                presentation.unsupportedReason =
                    "References DVD-Video title \(video.titleSet):\(video.title); DVD-Video extraction is not supported yet."
            } else if audioSectors <= 0 {
                throw DVDError("Missing audio files for title set \(titleSet).")
            }
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
                guard first <= last, presentation.videoReference != nil || last < audioSectors, last < Int32.max else {
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
                do {
                    _ = try presentation.decodingRuns()
                } catch {
                    presentation.unsupportedReason = String(describing: error)
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
