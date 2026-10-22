# Ripping a Disc

## Metadata

When a disc appears, CDRip reads its table of contents and asks MusicBrainz which releases have it. The chip under the album name says how sure the match is:

| Chip | Meaning |
|---|---|
| Disc ID match | MusicBrainz knows this exact disc. |
| Nearly the same TOC | MusicBrainz does not know the disc ID, but these releases have almost the same track lengths. Check the release, and consider adding the disc ID to MusicBrainz (the link is in the release picker). |
| Several releases match | More than one release has the disc, and CDRip cannot tell which. Choose one. The choice is kept for the other discs of the set. |
| Not in MusicBrainz | No release has the disc. The rip works, but the files cannot be tagged yet. |

Other Releases shows every release that matches. A disc with CD-Text gets a switch between the MusicBrainz names and the names on the disc. The rip's tags always come from MusicBrainz.

## Read modes

- **Secure** reads each track once and checks it against AccurateRip. A track that does not match is read again, and the sectors that read differently are re-read until two reads agree. Then the whole disc is checked against the CUETools database and, if it still has errors, repaired with that database's repair data. Use Secure unless you have a reason not to.
- **Fast** reads each track once. It is for clean discs when time matters, or to see what a drive makes of a disc before a secure rip.

## Options for one rip

The Options button in the toolbar holds choices for the next rip only:

- **Folder.** By default a rip's folder is named from the release, in the rips folder. Choose another for this rip.
- **Pool earlier rips of this disc.** On by default when the rips folder has a rip of the same disc. Sectors that an earlier rip read right are kept, and where the rips disagree, the re-reads and the CTDB repair have more to work with.
- **Offline.** No AccurateRip, CTDB, or drive offset list. The names come from the lookup already made. Repair (see Verification) can check the rip later.

The Secure or Fast choice is kept between launches.

## While it rips

The status column shows each track's progress: the read, later reads, and rounds of re-reads. The status bar shows the whole rip, the drive's speed, and the time left. Under it, a graph shows the whole disc by position, each track to scale: a bar marks sectors with trouble, and its height is how many of the sectors at that spot are marked. Orange is a sector the drive flagged or that reads disagreed on and then settled, blue a sector that never agreed but CTDB fixed, red a sector that never agreed or could not be read. The line is the read under way. Hold the pointer over a track for its numbers.

Behind another app, the Dock icon shows a progress bar, and when the rip is done, the icon bounces and a notification says how it went (macOS asks once whether CDRip may send notifications).

Stop ends the rip after the read under way. The tracks ripped so far stay in the folder, and a later rip of the same disc can use them.

## Where the files go

Each rip gets a folder in the rips folder (Settings › General), named from the release: the WAV files, `disc.json` and `Rip Report.md` with every detail, a CUE sheet, and the cover. With "Encode the disc into the library" on, the album is encoded into the library after the rip, and a rip whose tracks are all verified is deleted unless you keep it.
