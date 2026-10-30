# Welcome to Silverside

Silverside rips audio CDs on the Mac with the care of Exact Audio Copy: every track is checked against two databases of other people's rips, damaged discs are read again until the data agrees, and the result is a folder of WAV files with a report, or a tagged album in your music library.

## The window

- **Drives** are in the sidebar. Each shows the disc in it. Silverside sees a disc as soon as macOS does.
- **The disc** is in the middle: the cover, the album and artist from MusicBrainz, and the tracks with their rip status.
- **The toolbar** has Eject, Look Up Metadata, Options for the next rip, the read mode (Secure or Fast), and Rip Disc (Stop while a rip runs).
- **The status bar** shows what the rip is doing, how far it is, and the time left. Show Log opens the rip's log. With "Rip it at once" on in Settings, it counts down before a rip starts by itself, with Rip Now and Cancel.
- **Recent Rips** lists the newest rips: the rips in your rips folder, and the rips that were encoded into the library (their reports stay in the album folders, marked "encoded"). Select one to see its results and report. **All Rips** at the end of the list, or Rip History in the View menu (⌘Y), is every rip in a table you can search and sort. Its Medium column says what each disc is, as its logo does (CD, CD-Text, Enhanced CD, HDCD, DTS, and so on), and for HDCD what the codes ask for or that the files hold the decode: search for "HDCD" or "Enhanced" to find those rips.
- **The history keeps every rip**, also after you move its album out of the library (to a NAS, for example) or delete it. Silverside keeps its own copy of each rip's report, so such a rip stays in Rip History, marked "Moved or deleted", with its report and graph, and still counts in the About window. **Look for Moved Rips…** in Rip History looks in a folder you choose and keeps the rips' new places; **Remove from History** forgets one. To delete a rip that is still there, such as a second rip of a disc tagged with the wrong release, right-click it in Recent Rips or Rip History and choose **Move to Trash…**. A rip in the rips folder is its folder with the WAV files; a rip in the library is its report, its encoded files, its CUE sheet, and its disc image. Files that another rip in the same album folder uses stay, as does the cover. The Trash can put them back. While a rip runs, Move to Trash waits for it to end.
- **Sets** lists the releases of several discs that you have started: each disc's state, and the work left. Back and Forward in the toolbar (⌘[ and ⌘]) go between the places you have looked at.

## A rip, step by step

1. Insert a disc. Apple Music may open too; you can close it, or leave it open. However, you should set “When a CD is inserted” to Show CD in the Music app's settings, so that Music does not play or import the disc while Silverside reads it. Troubleshooting has a hidden macOS setting that keeps Music from opening at all.
2. Check the album and the tracks. If several releases match, choose one with Other Releases.
3. Click Rip Disc, or uncheck tracks and click Rip Selected. With "Rip it at once" on in Settings › General, a disc whose release is certain rips by itself a few seconds after it goes in.
4. Watch the status. A green check means AccurateRip or the CUETools database verifies the track.
5. At the end, a banner sums up the rip, and Show in Finder opens its folder. If encoding is on in Settings, the album goes into your library, and the Encoding column shows each track's file. If the library already has the album, Silverside asks before it replaces the files; if you keep them, the rip stays in the rips folder.

The first time Silverside opens, it asks what a rip should become: Apple Lossless, FLAC, AAC, MP3 (once the LAME encoder is installed), or WAV files only. Settings › General changes the choice later, and Help › Welcome to Silverside shows the welcome again.

The `silverside` command-line tool does the same work from a terminal, with the same settings.
