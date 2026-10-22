import Foundation

/// What a rip did and found, for each track and for the disc. `cdrip rip` writes it as
/// `disc.json` in the rip's folder, so that the rip can be checked and encoded later
/// without the disc.
public struct RipReport: Codable, Equatable, Sendable {
    public struct Drive: Codable, Equatable, Sendable {
        public var vendor: String
        public var product: String
        public var revision: String
        public var readOffset: Int
        /// Where the read offset came from, such as "AccurateRip's drive list".
        public var offsetSource: String

        public init(vendor: String, product: String, revision: String, readOffset: Int, offsetSource: String) {
            self.vendor = vendor
            self.product = product
            self.revision = revision
            self.readOffset = readOffset
            self.offsetSource = offsetSource
        }
    }

    public enum AccurateRipStatus: String, Codable, Sendable {
        /// The track matches AccurateRip.
        case accurate
        /// The track matches AccurateRip at other offsets only: it is free of errors.
        case otherPressings
        /// The disc is not in AccurateRip, or the rip was offline.
        case notInDatabase
        /// The track does not match AccurateRip.
        case notAccurate
    }

    public struct Track: Codable, Equatable, Sendable {
        public var number: Int
        public var file: String
        public var startLBA: Int
        public var sectors: Int
        public var preEmphasis: Bool
        public var accurateRip: AccurateRipStatus
        /// The submissions for the v1 and the v2 checksum, when the track is accurate.
        public var accurateRipConfidence: [Int]?
        /// The drive offsets at which the first read matches AccurateRip.
        public var matchingOffsets: [Int]
        /// Reads of the whole track, the first included.
        public var fullReads: Int
        /// Rounds of re-reads of suspect sectors.
        public var rereadRounds: Int
        /// Sectors, counted from the track's start, that read differently on different reads.
        public var suspectSectors: [Int]
        /// Suspect sectors whose data reads could not decide.
        public var unresolvedSectors: [Int]
        /// Sectors, counted from the track's start, with C2 errors in the first read. Nil if C2 was not read.
        public var c2Sectors: [Int]?
        /// The shifts, in samples, of reads that lost their place and were left out.
        public var shiftedReads: [Int]?
        /// Sectors, counted from the track's start, that the first read could not read.
        public var unreadableSectors: [Int]?
        /// The most submissions of a CTDB entry whose track CRC matches. 0 if none; nil if not checked.
        public var ctdbConfidence: Int?
        /// Samples that the CTDB repair changed.
        public var repairedSamples: Int
        /// The track's ISRC, from the Q subchannel.
        public var isrc: String?
        /// The track's pregap (index 00 to index 01) in sectors, from the Q subchannel. For track 1,
        /// the part of the disc before it. The pregap of a later track is at the end of the track before it.
        public var pregapSectors: Int?

        public init(
            number: Int, file: String, startLBA: Int, sectors: Int, preEmphasis: Bool,
            accurateRip: AccurateRipStatus, accurateRipConfidence: [Int]? = nil, matchingOffsets: [Int] = [],
            fullReads: Int = 1, rereadRounds: Int = 0, suspectSectors: [Int] = [], unresolvedSectors: [Int] = [],
            ctdbConfidence: Int? = nil, repairedSamples: Int = 0
        ) {
            self.number = number
            self.file = file
            self.startLBA = startLBA
            self.sectors = sectors
            self.preEmphasis = preEmphasis
            self.accurateRip = accurateRip
            self.accurateRipConfidence = accurateRipConfidence
            self.matchingOffsets = matchingOffsets
            self.fullReads = fullReads
            self.rereadRounds = rereadRounds
            self.suspectSectors = suspectSectors
            self.unresolvedSectors = unresolvedSectors
            self.ctdbConfidence = ctdbConfidence
            self.repairedSamples = repairedSamples
        }
    }

    public struct CTDBResult: Codable, Equatable, Sendable {
        public enum Status: String, Codable, Sendable {
            /// The rip matches an entry with no changes.
            case verified
            /// The repaired rip matches an entry.
            case repaired
            /// Some tracks were repaired, and their track CRCs match an entry.
            case partlyRepaired
            /// No entry verifies or repairs the rip.
            case notVerified
            /// The disc is not in CTDB.
            case notInDatabase
            /// Not checked: the rip is offline, or does not have every track.
            case notChecked
        }

        public var status: Status
        /// The entry that verifies or repairs the rip.
        public var entry: Int?
        /// The entry's submissions.
        public var confidence: Int?
        /// The shift, in samples, between the rip and the entry.
        public var shift: Int?
        /// Entries that match the rip's alignment but have no repair data.
        public var entriesWithoutRepairData = 0

        public init(status: Status, entry: Int? = nil, confidence: Int? = nil, shift: Int? = nil) {
            self.status = status
            self.entry = entry
            self.confidence = confidence
            self.shift = shift
        }

        public init(_ result: DiscRepairer.Result) {
            switch result.outcome {
            case .verified(let entry, let shift):
                self.init(status: .verified, entry: entry.id, confidence: entry.confidence, shift: shift)
            case .repaired(let entry, let shift, _):
                self.init(status: .repaired, entry: entry.id, confidence: entry.confidence, shift: shift)
            case .partlyRepaired(let entry, let shift, _, _):
                self.init(status: .partlyRepaired, entry: entry.id, confidence: entry.confidence, shift: shift)
            case .notVerified:
                self.init(status: .notVerified)
            }
            entriesWithoutRepairData = result.entriesWithoutRepairData
        }
    }

    public var program = "Silverside \(CDRipVersion.string)"
    public var date: Date
    public var drive: Drive
    /// True for a secure rip, with re-reads; false for a single pass.
    public var secure: Bool
    /// The TOC as CTDB writes it: each audio track's start LBA, then the lead-out.
    public var toc: String
    public var musicBrainzDiscID: String
    public var freedbDiscID: String
    public var accurateRipDiscID: String
    public var tracks: [Track]
    public var ctdb: CTDBResult
    /// The disc's MCN (barcode), from the Q subchannel.
    public var mcn: String?
    /// The disc's CD-Text, if it has any.
    public var cdText: CDText?
    /// Audio before track 1 (hidden track one audio), if the disc has it.
    public var hiddenTrack: HiddenTrack?

    public struct HiddenTrack: Codable, Equatable, Sendable {
        public var file: String
        public var sectors: Int
        /// The largest sample value, as a 16-bit magnitude.
        public var peak: Int
        /// True if two reads agreed. AccurateRip and CTDB do not cover this audio.
        public var readsAgree: Bool
        public var reads: Int

        public init(file: String, sectors: Int, peak: Int, readsAgree: Bool, reads: Int) {
            self.file = file
            self.sectors = sectors
            self.peak = peak
            self.readsAgree = readsAgree
            self.reads = reads
        }
    }
    /// The MusicBrainz release that the rip used for its names, with every disc's tracks.
    public var release: MusicBrainzRelease?
    /// The files that the rip wrote in its folder, as paths relative to it: the WAV files,
    /// the suspects, the reports, and the artwork. `RippedDisc.deleteRipFiles` deletes
    /// these and nothing else. Nil in reports from before CDRip kept the list.
    public var files: [String]?

    public init(date: Date = Date(), drive: Drive, secure: Bool, toc: TOC, tracks: [Track], ctdb: CTDBResult) {
        self.date = date
        self.drive = drive
        self.secure = secure
        self.toc = toc.ctdbTOCString
        musicBrainzDiscID = toc.musicBrainzDiscID
        freedbDiscID = String(format: "%08x", toc.freedbDiscID)
        accurateRipDiscID = toc.accurateRipDiscID.name
        self.tracks = tracks
        self.ctdb = ctdb
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Reads a report: a rip's disc.json, or an archive manifest that holds one under
    /// "ripReport" (the manifest's release fills in for a report without one). A manifest
    /// from before rips had reports has none to read, and throws.
    public static func read(from url: URL) throws -> RipReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: url)
        if let report = try? decoder.decode(RipReport.self, from: data) { return report }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let nested = object?["ripReport"] else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "\(url.lastPathComponent) has no rip report."))
        }
        var report = try decoder.decode(RipReport.self, from: JSONSerialization.data(withJSONObject: nested))
        if report.release == nil, let release = object?["release"] {
            report.release = try? JSONDecoder().decode(
                MusicBrainzRelease.self, from: JSONSerialization.data(withJSONObject: release))
        }
        return report
    }
}

extension RipReport {
    /// True if AccurateRip or CTDB proves every track, and the reads of a hidden track agree.
    /// `RippedDisc` uses the same rule for each track.
    public var isVerified: Bool {
        let wholeDisc = ctdb.status == .verified || ctdb.status == .repaired
        let tracksVerified = tracks.allSatisfy {
            wholeDisc || $0.accurateRip == .accurate || $0.accurateRip == .otherPressings
                || ($0.ctdbConfidence ?? 0) > 0
        }
        return tracksVerified && hiddenTrack?.readsAgree != false
    }
}

extension RipReport.Track: Identifiable {
    /// The track number: a report has each track once.
    public var id: Int { number }
}
