import Testing

@testable import SilversideKit

struct CueSheetTests {
    /// Tracks 6 and 7 of *Dozin' at the Knick* disc 3: track 7 has a pregap of 00:07:71
    /// (596 sectors), at the end of track 6's file. Track 1 has 32 sectors before it.
    @Test func putsAPregapAtTheEndOfTheFileBefore() {
        var sheet = CueSheet(
            title: "Dozin' at the Knick", performer: "Grateful Dead", catalog: "0078221402521",
            tracks: [
                .init(number: 1, file: "03-01 Space.flac", sectors: 4793, pregapSectors: 32, title: "Space"),
                .init(
                    number: 6, file: "03-06 And We Bid You Goodnight.flac", sectors: 13510,
                    title: "And We Bid You Goodnight", isrc: "USGD19600006"),
                .init(
                    number: 7, file: "03-07 Space.flac", sectors: 3270, pregapSectors: 596, title: "Space \"reprise\"",
                    preEmphasis: true, copyPermitted: true),
            ])
        sheet.remarks = ["DATE 1996", "DISCID 9610710C"]
        #expect(
            sheet.text == """
                REM DATE 1996
                REM DISCID 9610710C
                CATALOG 0078221402521
                PERFORMER "Grateful Dead"
                TITLE "Dozin' at the Knick"
                FILE "03-01 Space.flac" WAVE
                  TRACK 01 AUDIO
                    TITLE "Space"
                    PREGAP 00:00:32
                    INDEX 01 00:00:00
                FILE "03-06 And We Bid You Goodnight.flac" WAVE
                  TRACK 06 AUDIO
                    TITLE "And We Bid You Goodnight"
                    ISRC USGD19600006
                    INDEX 01 00:00:00
                  TRACK 07 AUDIO
                    TITLE "Space 'reprise'"
                    FLAGS DCP PRE
                    INDEX 00 02:52:14
                FILE "03-07 Space.flac" WAVE
                    INDEX 01 00:00:00

                """)
    }

    /// A hidden track before track 1, and a pregap before track 2, in one sheet.
    @Test func putsAHiddenTrackAndLaterPregapsTogether() {
        var sheet = CueSheet(tracks: [
            .init(number: 1, file: "01 One.flac", sectors: 4500, pregapSectors: 32),
            .init(number: 2, file: "02 Two.flac", sectors: 3000, pregapSectors: 150),
        ])
        sheet.hiddenTrackFile = "00 Hidden Track.flac"
        #expect(
            sheet.text == """
                FILE "00 Hidden Track.flac" WAVE
                  TRACK 01 AUDIO
                    INDEX 00 00:00:00
                FILE "01 One.flac" WAVE
                    INDEX 01 00:00:00
                  TRACK 02 AUDIO
                    INDEX 00 00:58:00
                FILE "02 Two.flac" WAVE
                    INDEX 01 00:00:00

                """)
    }

    /// The same disc as one image: each index is a time in the one file.
    @Test func placesEveryIndexInADiscImage() {
        var sheet = CueSheet(tracks: [
            .init(number: 1, file: "01 One.flac", sectors: 4500, pregapSectors: 32),
            .init(number: 2, file: "02 Two.flac", sectors: 3000, pregapSectors: 150),
        ])
        sheet.imageFile = "Album.flac"
        #expect(
            sheet.text == """
                FILE "Album.flac" WAVE
                  TRACK 01 AUDIO
                    PREGAP 00:00:32
                    INDEX 01 00:00:00
                  TRACK 02 AUDIO
                    INDEX 00 00:58:00
                    INDEX 01 01:00:00

                """)
        // With the hidden track one audio at the start of the file.
        sheet.hiddenTrackSectors = 32
        #expect(
            sheet.text == """
                FILE "Album.flac" WAVE
                  TRACK 01 AUDIO
                    INDEX 00 00:00:00
                    INDEX 01 00:00:32
                  TRACK 02 AUDIO
                    INDEX 00 00:58:32
                    INDEX 01 01:00:32

                """)
    }

    @Test func writesTimesInFrames() {
        #expect(
            CueSheet.time(0) == "00:00:00" && CueSheet.time(74) == "00:00:74" && CueSheet.time(4500 + 76) == "01:01:01")
    }
}
