# Welcome to CDRip

CDRip rips audio CDs on the Mac with the care of Exact Audio Copy: every track is checked against two databases of other people's rips, damaged discs are read again until the data agrees, and the result is a folder of WAV files with a report, or a tagged album in your music library.

## The window

- **Drives** are in the sidebar. Each shows the disc in it. CDRip sees a disc as soon as macOS does.
- **The disc** is in the middle: the cover, the album and artist from MusicBrainz, and the tracks with their rip status.
- **The toolbar** has Eject, Look Up Metadata, the read mode (Secure or Fast), and Rip Disc.
- **The status bar** shows what the rip is doing, how far it is, and the time left. Show Log opens the rip's log.
- **Recent Rips** lists the rips in your rips folder. Select one to see its results and report.

## A rip, step by step

1. Insert a disc. Apple Music may open too; you can close it, or leave it open. However, you should set "When CD inserted: Show" as the default action in Apple Music Settings to avoid automatically playing or ripping the CD through Apple Music.
2. Check the album and the tracks. If several releases match, choose one with Other Releases.
3. Click Rip Disc, or uncheck tracks and click Rip Selected.
4. Watch the status. A green check means the track matches AccurateRip.
5. The rip's folder opens from the banner at the end. If encoding is on in Settings, the album goes into your library.

The `cdrip` command-line tool does the same work from a terminal, with the same settings.
