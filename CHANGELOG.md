# Changelog

What changed in each version of Silverside, the app and the `silverside`
command-line tool.

## 0.7 (not released yet)

### Added

- **HDCD recognition:** each track of a rip is checked for HDCD codes. The
  header and the result show the HDCD logo, with "codes only" when the codes
  ask for nothing (a decoder would play the same audio, as on most discs with
  the logo), or "peak extend" or "gain" when an HDCD decoder would change the
  audio. Before the rip, the logo shows when MusicBrainz lists the disc as
  HDCD. The report has an HDCD table for each track, and the encoded files
  of a disc with HDCD codes are tagged `MEDIA=HDCD`, as MusicBrainz names
  the medium.
- `silverside hdcd` looks for HDCD codes in audio files and folders, such as
  rips and albums from before.
- **HDCD decoding**, as an option: a disc whose codes ask for peak extend or a
  gain adjustment can be decoded into 20-bit FLAC or Apple Lossless files
  (HDCD's own resolution; 24-bit for AIFF and WAV) tagged `HDCD=decoded`, with
  ReplayGain measured on the decode. The app asks before it encodes such a
  disc, and advises decoding, except for AIFF and WAV, whose 24-bit files are
  half again as large; Settings › Encoding can answer for every disc (`hdcd`:
  ask, decode, keep; `--hdcd` on the command line). In a set, a disc whose
  codes ask for nothing is decoded too when another disc is, so that the
  discs play at one level. **Decode HDCD…** on an earlier rip makes a decoded
  copy beside the album, as "<Album> (HDCD)" or another name you give, or
  decodes in place of its files, even after the rip's WAV files are gone; in
  place, no file is replaced until every track is decoded and checked.
- `silverside encode` takes an album folder in the library as its input,
  encoding it again from its lossless files, each checked against the rip's
  CRC-32; `--hdcd-copy` writes the decoded copy beside it.

### Changed

- A click on a cover shows it at full size in Quick Look, and the cover's
  menu has Quick Look too. Choose Cover… is in the menu; a click still
  chooses one where there is no cover yet.

## 0.6 (2026-10-23)

### Added

- **Play a track** to check it: a play button on each track of the disc in a
  drive, read as a rip reads it, and on each track of an earlier rip, from its
  WAV file or its encoded file. A bar at the bottom of the window has pause,
  a position slider, and stop. One track plays at a time, and a rip or a repair
  on the drive stops it.
- **Track info and disc info:** an info button at the end of each track's
  row shows what MusicBrainz knows of the track (artist, composers, lyricists,
  the album's genre, the recording ID) with the disc's ISRC and, for an
  earlier rip, its checksums and the tags in its encoded file, as a player
  reads them. A disc info button in the header, and in an earlier rip's
  toolbar, shows the release (date, country, status, barcode, labels, release
  group, discs, cover art) and the disc (its IDs, MCN, CD-Text, media type,
  pre-emphasis). The genre shows as a chip in the header. The app looks the
  chosen release up in full when the disc goes in, so all of it is there
  before the rip, and the rip sends no request of its own.
- A composer or lyricist whose name MusicBrainz has in another script, such as
  Արամ Խաչատրյան, is tagged with the name in your language (Aram Khachaturian)
  and shown with both. The report keeps both.
- The Markdown report's track table has a Composer column when MusicBrainz
  names one, and its Disc table the genre.
- **Rip a disc when it goes in** (Settings › General): when MusicBrainz names
  the disc's release for certain and the disc is not ripped yet, the rip
  starts after five seconds, with Rip Now and Cancel in the status bar.
  Otherwise the status bar says why the disc waits for you.
- **Add the files to the Music app** after encoding (Settings › General, or
  `--add-to-music` on `rip` and `encode`), in every format but FLAC, which
  Music cannot read. Music adds them where they are, or copies them if its own
  settings say so. macOS asks once whether Silverside may control Music.
- **Edit an earlier rip's track titles and artists,** in its track table, as
  before a rip. A moment after a change, the encoded files take the new names
  and are renamed; the other files are not touched.
- An earlier rip that is not encoded has an **Encode** button.

### Changed

- **The CTDB check is many times faster.** Its checksums use the system's
  CRC-32, which is the slow part of checking a disc stored at another
  pressing's alignment, and the search for the alignment and the repair of
  the columns run on every core. The status bar says what the check is doing,
  and the log names each entry's shift.
- **Sets.** A multi-disc release among the earlier rips has a view of its own,
  from the sidebar's Sets section or the set chip on a disc: each disc's state
  (still to do, ripped, verified, encoded), the album's names, which every
  disc shares, and its cover. Encode Discs puts the verified discs that are
  not in the library yet there, and Update the Library writes the names and
  the cover into every encoded disc's files, renames the files and the album
  folder as the templates say, and writes the CUE sheets again. The set's
  summary now tells a disc that is ripped but not verified or not encoded
  from one that is done, and a box set's DVD is not counted as a disc to rip.
  A disc that MusicBrainz lists only by its track lengths gets the release
  chosen for the set's other discs. Open a disc's row to see its tracks and
  their results, with each disc's time; double-click a row to show that disc.
- **Back and Forward** arrows in the toolbar, as in a browser: after Show
  takes you from a set to one of its discs, Back takes you to the set again.
  The keys are ⌘[ and ⌘], or ⌘← and ⌘→ when you are not typing in a field.
- **Change the cover after a rip.** Drop an image on an earlier rip's cover,
  or choose one from its menu, and it goes into the rip's folder, the album
  folder, and the tags of the encoded files; the audio is not touched. The
  menu can also put the Cover Art Archive's cover back. A cover you choose is
  kept for the release, so the other discs of a set, and a later rip of the
  same release, get it. `silverside metadata --cover x.jpg --retag` does the
  same from the terminal.
- **ReplayGain tags,** on by default: each track's gain and peak, and the
  album's, measured as EBU R 128 does, written into every format, and listed
  in the rip report. Settings › Encoding, or `encode --no-replay-gain`. For a
  set, the album is the whole set: once every disc is in the library, every
  disc's files get the album gain over all of them, so a show split across
  discs plays at one level.
- **Tracks encode in parallel,** up to four at a time (half the Mac's cores,
  at least two), each still checked against the rip before it goes into the
  library.
- **The log and the report keep the times.** Each line of the rip's log starts
  with the time, so it says when each track, the CTDB check, and the encoding
  finished, and the last line says how long the rip took. The report says when
  the rip started, how long the tracks took (and the longest), the CTDB check,
  the whole rip, and the encoding.
- A later read of a track says how many there can be ("read 2 of up to 4"),
  and the time left says "plus re-reads" while a track is read again.
- Update the Library, and a name changed after a rip, write only the FLAC and
  Apple Lossless or AAC files whose tags change, which matters for a library
  on a network volume.

### Fixed

- An earlier rip's track table showed the names from MusicBrainz, not the
  ones you had edited before the rip.
- The cover art was downloaded after the last track, while the status bar said
  only "Finishing the rip", and with "every image" chosen a release's
  full-size scans could take a minute. The download now runs while the disc
  is read, and the status bar says when the rip is still waiting for it.
- In 0.5, MusicBrainz refused every disc lookup ("lookup failed" for each disc),
  because the lookup asked for relationships that only a release lookup may
  have. The disc lookup is as it was, and a rip looks the chosen release up
  once more for the composers.

## 0.5 (2026-10-23)

### Added

- **Checksums in the rip report:** each track's CRC-32 as Exact Audio Copy
  and XLD print it, the "skip zero" form, and its AccurateRip checksums, so
  that rips can be compared across programs.
- **Test and copy**, off by default: one more read of each track after its
  rip, with its CRC-32 beside the copy's in the report. Settings › Ripping,
  or `rip --test`.
- **The media type** in the report and in `silverside info`: a pressed CD, a
  CD-R, or a CD-RW.
- **More tags from MusicBrainz:** composers, lyricists, the genre, and sort
  names for the artist and the album artist.
- **The report records the encoding:** the format, the encoder and its
  settings, and each track's file. An "Encoded" chip and an Encoding column
  show it, for a new rip and an earlier one.
- An earlier rip shows its cover beside the result.
- A spinner while a rip or a MusicBrainz lookup is under way, and a status
  bar that says what the rip waits for.
- Help › Silverside Website. Acknowledgments names XLD and cyanrip as
  inspirations.

### Changed

- The website is [silverside.app](https://silverside.app). The About window
  opens it, and Silverside gives it to the services it asks.
- The bundle identifier is `app.silverside.Silverside`, the last of the
  rename from CDRip. macOS sees a new app: the welcome shows once more, and
  Fast mode and the window positions start afresh. Rips, settings, and drive
  profiles stay.

### Fixed

- The header said "not looked up" while MusicBrainz was being asked about a
  disc.
- The table of an earlier rip was too wide when the rip report was open.
- The rip report said "1 sectors".
- During a rip, the Rip Disc button stayed blue and dim. Stop takes its
  place, and the button is gray when there is nothing to rip.

## 0.4 (2026-10-22)

### Added

- **A welcome at the first launch.** It shows the CD drives that macOS has
  and asks what a rip should become: Apple Lossless, FLAC, AAC, MP3, or WAV
  files only. Help › Welcome to Silverside opens it again.
- **An About window**, with the version, how many discs you ripped and how
  many tracks are verified, the services Silverside uses, and
  Acknowledgments.
- **The MIT License.** The name "Silverside" and the icon and logo artwork are
  not covered by it. The app shows it from Acknowledgments, and
  `silverside license` prints it.
- **Silverside asks before it replaces files in your library.** When the
  library already has the album, a rip asks after it reads the disc: Replace,
  or Keep the Files, which keeps the rip for later. `silverside rip --encode`
  asks at a terminal, and `--overwrite` now works with `rip` as well as
  `encode`.
- **An Encoding column** in the track table, for each track's file while the
  album is encoded.
- **MP3 turns on by itself** when the LAME encoder is installed while the
  welcome or Settings is open. The environment variable `SILVERSIDE_LAME`
  names another `lame`, or with `none` acts as if there were none.
- **Help for common problems:** how to keep the Music app from opening when
  a CD goes in, why MP3 may not be a choice, and why a rip may not be
  encoded.
- **`docs/cli.md`**, the guide to the command-line tool.

### Changed

- Drives with a disc come first in the sidebar. A disc that goes in while
  the window shows an empty drive brings its drive into view.
- Without LAME, MP3 is left out of the formats in Settings › General (with a
  note), and its options in Settings › Encoding are dimmed.
- Settings › Encoding says what AAC is.
- The app's messages about encoding no longer name command-line options.
- Button titles use the ellipsis character (…).
- The help matches the app: the status names, what a rip folder holds, how
  pooling and repair work, and discs that MusicBrainz does not know.
- The README is for people who use the app, with a section on building from
  source; the command-line details moved to `docs/cli.md`.

### Fixed

- A second rip of a disc that was already in the library failed at the end,
  with "Use --overwrite" in the status bar.
- On macOS 15, the Rip button's disc turned white while it turned.
- The encoding progress counted a pre-emphasis warning as a track.

Checked on macOS 15.6.1 (a full rip, the drive test, and FLAC encoding) as
well as on the current macOS.
