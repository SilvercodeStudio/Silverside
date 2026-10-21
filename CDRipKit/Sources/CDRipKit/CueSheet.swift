/// A CUE sheet for a disc ripped to one file for each track.
///
/// CDRip's track files run from one track's index 01 to the next track's, so a pregap
/// (index 00) is at the end of the file before it: the "noncompliant" layout, from which a
/// burner or player can rebuild the disc exactly. Track 1's gap, which no file holds, is a
/// PREGAP of silence.
public struct CueSheet: Sendable {
    public struct Track: Sendable {
        public var number: Int
        /// The track's file name, as the CUE sheet names it (in the same folder).
        public var file: String
        public var sectors: Int
        /// The pregap in sectors: index 00 to index 01.
        public var pregapSectors: Int
        public var title: String?
        public var performer: String?
        public var isrc: String?
        public var preEmphasis: Bool
        public var copyPermitted: Bool

        public init(
            number: Int, file: String, sectors: Int, pregapSectors: Int = 0, title: String? = nil,
            performer: String? = nil, isrc: String? = nil, preEmphasis: Bool = false, copyPermitted: Bool = false
        ) {
            self.number = number
            self.file = file
            self.sectors = sectors
            self.pregapSectors = pregapSectors
            self.title = title
            self.performer = performer
            self.isrc = isrc
            self.preEmphasis = preEmphasis
            self.copyPermitted = copyPermitted
        }
    }

    public var title: String?
    public var performer: String?
    /// The MCN (barcode), 13 digits.
    public var catalog: String?
    /// Lines that start with REM, such as "DATE 1996" or "DISCID 9610710C".
    public var remarks: [String] = []
    /// The file of the audio before track 1 (hidden track one audio), if it was ripped: track
    /// 1's index 00 is there, in place of a PREGAP of silence.
    public var hiddenTrackFile: String?
    public var tracks: [Track]

    public init(title: String? = nil, performer: String? = nil, catalog: String? = nil, tracks: [Track]) {
        self.title = title
        self.performer = performer
        self.catalog = catalog
        self.tracks = tracks
    }

    /// The CUE sheet's text.
    public var text: String {
        var lines = remarks.map { "REM \($0)" }
        if let catalog, catalog.count == 13 { lines.append("CATALOG \(catalog)") }
        if let performer { lines.append("PERFORMER \(Self.quoted(performer))") }
        if let title { lines.append("TITLE \(Self.quoted(title))") }
        for (index, track) in tracks.enumerated() {
            // A track with a pregap starts in the previous file, which holds the pregap.
            let startsInPreviousFile = index > 0 && track.pregapSectors > 0
            let hidden = index == 0 ? hiddenTrackFile : nil
            if !startsInPreviousFile { lines.append("FILE \(Self.quoted(hidden ?? track.file)) WAVE") }
            lines.append(String(format: "  TRACK %02d AUDIO", track.number))
            if let title = track.title { lines.append("    TITLE \(Self.quoted(title))") }
            if let performer = track.performer { lines.append("    PERFORMER \(Self.quoted(performer))") }
            if let isrc = track.isrc { lines.append("    ISRC \(isrc)") }
            let flags = (track.copyPermitted ? ["DCP"] : []) + (track.preEmphasis ? ["PRE"] : [])
            if !flags.isEmpty { lines.append("    FLAGS \(flags.joined(separator: " "))") }
            if hidden != nil {
                lines.append("    INDEX 00 00:00:00")
                lines.append("FILE \(Self.quoted(track.file)) WAVE")
            } else if index == 0 && track.pregapSectors > 0 {
                lines.append("    PREGAP \(Self.time(track.pregapSectors))")
            }
            if startsInPreviousFile {
                lines.append("    INDEX 00 \(Self.time(tracks[index - 1].sectors - track.pregapSectors))")
                lines.append("FILE \(Self.quoted(track.file)) WAVE")
            }
            lines.append("    INDEX 01 00:00:00")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A time as CUE sheets write it: MM:SS:FF, with 75 frames a second.
    static func time(_ sectors: Int) -> String {
        String(format: "%02d:%02d:%02d", sectors / 4500, sectors / 75 % 60, sectors % 75)
    }

    /// Text in quotes. A quote in it becomes an apostrophe, as CUE sheets cannot hold one.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "'") + "\""
    }
}
