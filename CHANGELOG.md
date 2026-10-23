# Changelog

What changed in each version of Silverside, the app and the `silverside`
command-line tool.

## 0.5 (not released yet)

### Added

- **Checksums in the rip report:** each track's CRC-32 as Exact Audio Copy and
  XLD print it, EAC's "skip zero" variant, and the track's own AccurateRip v1
  and v2 checksums, in `disc.json` and in a Checksums table of the Markdown
  report, so that rips can be compared across programs.
- **Test and copy**, off by default (Settings › Ripping; `testAndCopy` in the
  settings, `rip --test`): after each track's rip, one more read of the track,
  with its CRC-32 beside the copy's in the report, as EAC does.
- **The media type** in the rip report and in `silverside info`: a pressed CD,
  a CD-R, or a CD-RW. A CD-R of a show is in neither database, which explains
  a rip that nothing can verify.
- **More tags from MusicBrainz:** the composers and lyricists of each track
  from its work relationships, the genre with the most votes, and sort names
  for the artist and the album artist (COMPOSER, LYRICIST, GENRE, ARTISTSORT,
  and ALBUMARTISTSORT, and their AAC and MP3 forms).
- **The rip report records the encoding:** the format, the encoder and its
  settings (AAC's mode and bit rate, or LAME's options), how the files were
  checked, and each track's file, in `disc.json`, the album folder's report,
  and the Markdown report. After a rip, and for an earlier rip, an "Encoded"
  chip and an Encoding column show it.
- **An earlier rip shows its cover** beside the result.
- **Help › Silverside Website** opens silverside.app.
- Acknowledgments names XLD and cyanrip, two rippers that were inspirations.
- **A small spinner shows when work is under way:** in the status bar during
  a rip, and while a disc is looked up in MusicBrainz. The status bar also
  says when it looks up the disc, finishes the rip, or waits for your answer.

### Changed

- Silverside's website is [silverside.app](https://silverside.app): the About
  window's Website button opens it, and Silverside names it to MusicBrainz and
  the other services it asks.
- The app's bundle identifier is `app.silverside.Silverside`, the last part
  of the rename from CDRip. macOS treats it as a new app: the welcome shows
  once more at the next launch, and the choice of Fast mode and the window
  positions start afresh. Rips, settings, and drive profiles are not affected.

### Fixed

- While MusicBrainz was being asked about a new disc, the header said
  "not looked up" until the answer came.
- The table of an earlier rip was too wide for the window when the rip report
  was open.
- The rip report said "1 sectors".
- During a rip, the Rip Disc button stayed blue with dim text. Stop now takes
  its place, and the button is gray when there is nothing to rip.

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
