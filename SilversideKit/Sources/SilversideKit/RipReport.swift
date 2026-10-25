import Foundation

/// What a rip did and found, for each track and for the disc. `silverside rip` writes it as
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
        /// CRC-32 of the track's audio as it was written, as eight hex digits, as EAC and XLD
        /// print it, so that rips can be compared across programs. Nil in older reports.
        public var crc32: String?
        /// The same, leaving out the samples that are silent in both channels: EAC's "skip zero".
        public var crc32SkipZero: String?
        /// The CRC-32 of a second, separate read of the track (test and copy). Nil if there was none.
        public var testCRC32: String?
        /// The track's own AccurateRip v1 and v2 checksums, as eight hex digits each.
        public var accurateRipChecksums: [String]?
        /// The time the track's rip took, in seconds: every read and re-read. Nil in older reports.
        public var seconds: Int?
        /// The track's HDCD codes. Nil if it has none, and in older reports (see `RipReport.hdcd`).
        public var hdcd: HDCDCodes?

        /// Whether the test read gave the same audio as the copy, as read: a repair can change
        /// the copy after the test. Nil without a test read.
        public var testReadMatches: Bool?

        /// Records the checksums of the track's audio: its CRC-32s, and its AccurateRip checksums.
        public mutating func recordChecksums(of samples: [UInt32], isFirstTrack: Bool, isLastTrack: Bool) {
            crc32 = CRC32.hex(CRC32.checksum(of: samples[...]))
            crc32SkipZero = CRC32.hex(CRC32.checksumSkippingZeros(of: samples[...]))
            let checksum = AccurateRipAccumulator.checksum(
                of: samples[...], isFirstTrack: isFirstTrack, isLastTrack: isLastTrack)
            accurateRipChecksums = [CRC32.hex(checksum.v1), CRC32.hex(checksum.v2)]
        }

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

    public var program = "Silverside \(SilversideVersion.string)"
    /// When the rip ended and the report was written.
    public var date: Date
    /// When the rip started, before the lookups. Nil in older reports.
    public var started: Date?
    /// The time the CTDB check and repair took, in seconds. Nil if there was none, and in older reports.
    public var ctdbSeconds: Int?
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
    /// What the disc is: pressed, or a CD-R or CD-RW. Nil if the drive could not tell, and in older reports.
    public var media: DiscMediaType?
    /// The disc's CD-Text, if it has any.
    public var cdText: CDText?
    /// Audio before track 1 (hidden track one audio), if the disc has it.
    public var hiddenTrack: HiddenTrack?
    /// Whether the tracks have HDCD codes, from each track's `hdcd`. Nil in reports from
    /// before Silverside looked for them.
    public var hdcd: HDCDStatus?

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
    /// these and nothing else. Nil in reports from before Silverside kept the list.
    public var files: [String]?
    /// What the latest encoding made of the rip. Nil until the rip is encoded, and in reports
    /// from before Silverside kept it.
    public var encoding: Encoding?

    /// An encoding of the rip into the library: the format, its settings, and each track's file.
    public struct Encoding: Codable, Equatable, Sendable {
        public struct File: Codable, Equatable, Sendable {
            public var track: Int
            /// The file's name in the album folder.
            public var file: String

            public init(track: Int, file: String) {
                self.track = track
                self.file = file
            }
        }

        public var date: Date
        public var format: AudioFormat
        /// The program that wrote the audio: "Apple AudioToolbox", "LAME 3.100", or Silverside for WAV.
        public var encoder: String
        /// The AAC or MP3 settings; nil for the lossless formats, which have none.
        public var aac: AACOptions?
        public var mp3: MP3Options?
        /// The album folder in the library.
        public var folder: String
        public var files: [File]
        /// The time the encoding took, in seconds, checks included. Nil in older records.
        public var seconds: Int?
        /// The ReplayGain values written into the tags. Nil when they were not, and in older records.
        public var replayGain: ReplayGainRecord?
        /// True if the files hold the HDCD decode of the rip (at the format's `hdcdBits`), tagged HDCD=decoded.
        /// Nil (or false) when they hold the audio as it is on the disc.
        public var hdcdDecoded: Bool?
        /// Added to the album's title in the names and tags, as " (HDCD)" for a decoded copy
        /// beside the album as it is on the disc. Nil for the album itself.
        public var albumSuffix: String?
        /// The disc image (the whole disc in one file, with its CUE sheet beside it), if one was
        /// written. Nil in older records.
        public var image: String?

        /// The loudness of the album and its tracks, as the ReplayGain tags have them.
        public struct ReplayGainRecord: Codable, Equatable, Sendable {
            public struct Track: Codable, Equatable, Sendable {
                public var track: Int
                public var values: ReplayGain.Values

                public init(track: Int, values: ReplayGain.Values) {
                    self.track = track
                    self.values = values
                }
            }

            /// This disc's own values. Nil when every track is silent.
            public var album: ReplayGain.Values?
            public var tracks: [Track]
            /// The disc's blocks, for the gain of a multi-disc album. Nil in older records.
            public var histogram: ReplayGain.Histogram?
            /// For a disc of a multi-disc release: the album's values over every CD of the
            /// release, which the tags have as the album gain in place of `album`. Nil until
            /// every disc is encoded into the album folder.
            public var release: ReplayGain.Values?
            /// The discs that `release` covers.
            public var releaseDiscs: Int?

            public init(
                album: ReplayGain.Values?, tracks: [Track], histogram: ReplayGain.Histogram? = nil,
                release: ReplayGain.Values? = nil, releaseDiscs: Int? = nil
            ) {
                self.album = album
                self.tracks = tracks
                self.histogram = histogram
                self.release = release
                self.releaseDiscs = releaseDiscs
            }

            /// The values that the tags have as the album's: the whole release's, else the disc's.
            public var albumInTags: ReplayGain.Values? { release ?? album }
        }

        public init(
            date: Date = Date(), format: AudioFormat, encoder: String, aac: AACOptions? = nil, mp3: MP3Options? = nil,
            folder: String, files: [File], seconds: Int? = nil, replayGain: ReplayGainRecord? = nil
        ) {
            self.date = date
            self.format = format
            self.encoder = encoder
            self.aac = aac
            self.mp3 = mp3
            self.folder = folder
            self.files = files
            self.seconds = seconds
            self.replayGain = replayGain
        }

        /// The AAC or MP3 settings, for people to read: "VBR, quality 127", "lame -V 0". Nil for lossless.
        public var settingsText: String? {
            if let aac {
                switch aac.mode {
                case .vbr: return "VBR, quality \(aac.vbrQuality) of 127"
                case .vbrConstrained: return "constrained VBR around \(aac.bitRate) kbit/s"
                case .abr: return "average \(aac.bitRate) kbit/s"
                case .cbr: return "constant \(aac.bitRate) kbit/s"
                }
            }
            if let mp3 { return (["lame"] + mp3.lameArguments).joined(separator: " ") }
            return nil
        }

        /// How each file was checked after it was written.
        public var checkText: String {
            if hdcdDecoded == true {
                return format.isLossless
                    ? "HDCD decoded, at \(format.hdcdBits) bits: each file decodes to exactly the HDCD decode of the"
                        + " ripped audio."
                    : "HDCD decoded: each file decodes to the track's length; a lossy file cannot equal the rip."
            }
            return format.isLossless
                ? "Each file decodes to exactly the ripped audio."
                : "Each file decodes to the track's length; a lossy file cannot equal the rip."
        }

        /// The file of a track, if the encoding wrote one.
        public func file(ofTrack number: Int) -> String? {
            files.first { $0.track == number }?.file
        }

        /// Sets "encoding" in a report file (a rip's disc.json, or an archive manifest's
        /// "ripReport"), and keeps every other key.
        public func save(inReportAt url: URL) throws {
            var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let value = try JSONSerialization.jsonObject(with: encoder.encode(self))
            if var nested = object["ripReport"] as? [String: Any] {
                nested["encoding"] = value
                object["ripReport"] = nested
            } else {
                object["encoding"] = value
            }
            let data = try JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
        }
    }

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
