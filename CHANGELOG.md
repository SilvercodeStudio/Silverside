# Changelog

What changed in each version of Silverside, the app and the `silverside`
command-line tool.

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
