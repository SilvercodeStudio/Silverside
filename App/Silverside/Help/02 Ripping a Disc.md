# Ripping a Disc

## Metadata

When a disc appears, Silverside reads its table of contents and asks MusicBrainz which releases have it. The chip under the album name says how sure the match is:

| Chip | Meaning |
|---|---|
| Disc ID match | MusicBrainz knows this exact disc. |
| Nearly the same TOC | MusicBrainz does not know the disc ID, but these releases have almost the same track lengths. Check the release, and consider adding the disc ID to MusicBrainz (the link is in the release picker). |
| Several releases match | More than one release has the disc, and Silverside cannot tell which. Choose one. The choice is kept for the other discs of the set. |
| Not in MusicBrainz | No release has the disc. The names come from the disc's CD-Text, or you type them in the header and the track table. The files get those names, but no MusicBrainz IDs. |

Other Releases shows every release that matches. A disc with CD-Text gets a switch between the MusicBrainz names and the names on the disc. The rip's tags always come from MusicBrainz.

The cover comes from the Cover Art Archive. For a disc that has none there, or a better scan of your own, drop an image file on the cover, or click it to choose one. It is saved with the rip and embedded in the files. JPEG and PNG are kept as they are; other formats become JPEG. To keep a copy of any cover, drag it out to the Finder, or right-click it and choose Export Cover.

The info button at the end of a track's row shows everything known about the track: the artist, the composers and lyricists when MusicBrainz names them (with the name in your language beside one in another script), the album's genre, the length, the ISRC from the disc, and the MusicBrainz recording ID. All of it goes into the files' tags, and for an earlier rip that was encoded, the button also shows the tags in the file itself. The info button beside the header's chips shows the release (date, country, status, barcode, labels, release group, discs) and the disc's own codes (the disc IDs, MCN, CD-Text, media type). The album, the artist, and each track's title and artist can be edited; the rest comes from MusicBrainz as it is.

## Playing a track

The play button at the start of a track's row plays it from the disc, read the way a rip reads it, so a track that plays is one the drive can read. A bar at the bottom of the window shows the track, with pause, a slider to move within it, and stop. An earlier rip's tracks play the same way, from the rip's WAV files or the encoded files in the library. One track plays at a time; starting a rip, a repair, or a drive test on the drive stops it.

## Read modes

- **Secure** reads each track once and checks it against AccurateRip. A track that does not match is read again, and the sectors that read differently are re-read until two reads agree. Then the whole disc is checked against the CUETools database and, if it still has errors, repaired with that database's repair data. Use Secure unless you have a reason not to.
- **Fast** reads each track once. It is for clean discs when time matters, or to see what a drive makes of a disc before a secure rip.

## Options for one rip

The Options button in the toolbar holds choices for the next rip only:

- **Folder.** By default a rip's folder is named from the release, in the rips folder. Choose another for this rip.
- **Pool earlier rips of this disc.** On by default when the rips folder has a rip of the same disc. A track that an earlier rip got accurate replaces one that is not, and where the rips disagree, the CTDB repair has more versions to work with.
- **Offline.** No AccurateRip, CTDB, or drive offset list. The names come from the lookup already made. Repair (see Verification) can check the rip later.

The Secure or Fast choice is kept between launches.

## While it rips

The status column shows each track's progress: the read, later reads (up to four in all, until two agree), and rounds of re-reads of the sectors that differ (up to sixteen). The status bar shows the whole rip, the drive's speed, and the time left. Under it, a graph shows the whole disc by position, each track to scale: a bar marks sectors with trouble, and its height is how many of the sectors at that spot are marked. Dim orange is a sector the drive flagged, orange one that reads disagreed on and then settled, blue one that never agreed but CTDB fixed, and red one that never agreed or could not be read. The line is the read under way. Hold the pointer over a track for its numbers.

Behind another app, the Dock icon shows a progress bar, and when the rip is done, the icon bounces and a notification says how it went (macOS asks once whether Silverside may send notifications).

Stop ends the rip after the read under way. The tracks ripped so far stay in the folder, and a later rip of the same disc can use them.

## Where the files go

Each rip gets a folder in the rips folder (Settings › General), named from the release: the WAV files, `disc.json` and `Rip Report.md` with every detail, and the cover. With "Encode the disc into the library" on, the album is encoded into the library after the rip, with the cover, the report, and a CUE sheet in its folder. Then a rip whose tracks are all verified and encoded is deleted, unless you keep it.
