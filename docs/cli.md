# The `silverside` command-line tool

`silverside` does what the Mac app does, from a terminal: it shares the app's
engine and its settings file. See the [README](../README.md) for what
Silverside is and how it rips.

## Install

From a copy of this repository, with Xcode installed:

```sh
make install                    # silverside in /usr/local/bin (may need sudo)
make install PREFIX=~/.local    # or in ~/.local/bin
```

`make install` builds `silverside` for Apple silicon and Intel, and installs shell
completions for zsh, bash, and fish. `make uninstall` takes them away.

## Quick start

```sh
silverside drives                         # the drives, and the disc in each
silverside info -d asus                   # the disc: tracks, ISRCs, disc IDs
silverside rip -d asus                    # rip to WAV, verify, repair
silverside rip -d disk14 --encode         # rip, then encode into the library
silverside encode -i "<rip folder>"       # encode a rip later
```

`-d` takes a drive's short name, which `silverside drives` shows (its vendor, as
`asus` or `matshita`, or its model, as `bu50n`), or any part of the drive's name
that only one drive has, or the disc's BSD name (`disk14`). With one disc in one
drive, `-d` can be left out.

`silverside help <command>` explains each command, with examples.

Silverside is for archival copies of discs that you own, for your personal use,
at your own risk. The first `silverside rip` at a terminal asks you to agree to
this (type `yes`), and remembers the answer in the settings, which the app
shares. Without a terminal, as in a script, `rip` stops until you agree with
`silverside --accept-disclaimer`.

## Commands

| Command | What it does |
|---|---|
| `drives` | Lists the drives, their discs (named from an earlier MusicBrainz lookup), read offsets, and caches. Sets a drive's offset by hand (`--set-offset`), measures its cache (`--measure-cache`), or writes a drive report for a bug report (`--report`). |
| `info` | Shows a disc's TOC, pregaps, ISRCs, MCN, CD-Text, disc IDs, and whether AccurateRip and CTDB have it. |
| `cdtext` | Shows every field of a disc's CD-Text, in each of its languages, or its raw packs (`--packs`). |
| `rip` | Rips a disc to WAV files: verifies, re-reads, repairs, looks up the release, saves the cover, and can encode. |
| `repair` | Repairs rips again with CTDB: pools rips from several drives, and re-reads with the disc in a drive. |
| `check` | Looks earlier rips up in AccurateRip and CTDB again, for a new release that they did not have yet, and checks the rip's audio (its WAV files, or the album's lossless files) against them. |
| `metadata` | Shows the MusicBrainz releases for a disc, and keeps the chosen one in a rip's `disc.json`; `--set` edits names, `--cover` gives a cover, and `--retag` writes both into the album's encoded files. |
| `encode` | Encodes rips into the library, named and tagged, and checks each file. |
| `video` | Makes a video of a CD+G disc's rip: the graphics drawn as a CD+G player draws them, over the rip's audio (Apple Lossless, exactly as ripped, or `--audio aac`), the whole disc in one `.m4v` with a chapter for each track, named by its title. A CD+EG disc's video shows its 256 colors, as a CD+EG player does; `--picture g` shows it as a CD+G player does, in 16 colors, as "… (CD+G).m4v", and `--picture both` makes the two. It goes into the album folder when the rip was encoded, named after the album, else into the rip's folder; an album whose rip is gone works too (give its `Rip Report.json`), if it is lossless. `--codec hevc` makes smaller files; `--scale` sets the size (4: 1200 × 864). |
| `hdcd` | Looks for HDCD codes in audio files and folders (WAV, AIFF, FLAC, Apple Lossless), such as rips and albums from before. |
| `config` | Shows and changes the settings. |
| `eject` | Ejects the disc from a drive (`-d`), or from every drive (`--all`: CDs, DVDs, and Blu-ray discs). A drive named with `-d` ejects a disc that macOS never recognized, through Disc Recording as `drutil eject` does, or opens its empty tray. A drive that hangs in a read is safer to unplug than to eject. |
| `license` | Shows the notice and the license (the GNU GPL, version 3 or later), and the code from others that the CLI includes. |

## More options

`silverside help <command>` lists every option. Some that the rest of this
page does not name:

- `rip --tracks 1,3-5` rips those tracks only (a data track's number saves
  it); `--release <MusicBrainz ID>` chooses the release, and the choice is kept
  for the other discs of the release.
- `rip --offset N` uses that read offset, in samples, for this rip only.
- `rip --single-pass` reads each track once, with no re-reads (the app's Fast
  mode); `--no-repair` checks the rip against CTDB but does not repair it;
  `--no-c2` does not ask the drive for C2 error flags.
- `rip --offline` looks up nothing: no AccurateRip, CTDB, MusicBrainz, or
  drive offset list.
- `rip --eject` ejects the disc after the rip if every track is verified.
- `drives --clear-offset` removes an offset that `--set-offset` set.
- `metadata --release <MusicBrainz ID>` chooses the release; `--manual` makes
  one from the disc's CD-Text, for a disc that MusicBrainz does not know, to
  fill in with `--set`; `--clear-edits` removes every edit of the disc and of
  its release's album names.
- `cdtext --json` prints the CD-Text as JSON.

## What a rip makes

A rip's folder is in `~/Music/Silverside Rips` (the `rips` setting), named from the
release, such as `Grateful Dead - Cornell 5-8-77 (Disc 1)`, and holds:

- `Track 01.wav` and so on: one file for each track, from its index 01 to the
  next track's (a pregap belongs to the track before it)
- `disc.json`: the rip report, with the TOC and the MusicBrainz release, and
  after `rip --encode`, the encoding: the format, the encoder and its settings,
  and each track's file (the album folder's `Rip Report.json`, or `Rip Report (Disc N).json` in a set, has it too)
- `cover.jpg`, and `Artwork/` with `--artwork all`
- `Track NN.suspects`, for tracks that are not verified: the other values that
  reads gave for their suspect samples, for a later `silverside repair`
- `Rip Report.md`, and `Track 00.wav` if the disc has hidden track one audio
- `Track 01.cdg` and so on, for a disc with CD+G graphics (karaoke lyrics,
  pictures), in a drive that gives the subchannel: each track's graphics, 300
  packs a second from its index 01, the file that karaoke players and VLC
  read. Each pack is checked by its own parity, and one or two wrong symbols
  are put right; a pack damaged past that is read again, then left out, and
  a correction of two is kept only when a second read gives the same pack. The
  file keeps a CD+EG disc's extended graphics too. The encoding copies each
  beside its track's file in the album folder, by the same name
  (`01 Song.cdg` beside `01 Song.flac`), as karaoke programs pair them
- a video of the CD+G graphics (`--video`, or the `cdGraphicsVideo` setting):
  the whole disc in one `.m4v`, named after the album, in the album folder, or
  here when the rip is not encoded
- `Rip Report.log`: the rip in the layout of Exact Audio Copy's logs (UTF-8,
  CR LF), for people and tools that read those; the encoding writes one beside
  the album's report too. `--no-eac-log` (or the `writeEACLog` setting) leaves it
  out. It names Silverside as its program, and has no EAC log checksum
- `Track 15.iso` and so on, for a data track (an Enhanced CD's extras), if it is
  saved (`--data-tracks`, or the `dataTracks` setting). The encoding copies it
  into the album folder as `Data track.iso`, and the files of its ISO 9660 file
  system into a `Data track` folder. The image holds the track exactly; its
  file system counts from the start of the disc, which the report gives

A rip that is stopped keeps the tracks it finished in its folder. The next rip
of the disc, in any drive, goes into the same folder and keeps each track that
AccurateRip says is accurate there (or in a `--pool` folder): it reads only the
others, then checks the whole disc with CTDB as usual. `--read-all` reads every
track again.

The report also says whether the tracks have HDCD codes, and what they ask of
a decoder (peak extend, a gain adjustment, or nothing), and the encoded files
of such a disc are tagged `MEDIA=HDCD`. For a disc whose codes
ask for something, `--hdcd decode` (or the `hdcd` setting) decodes them into
20-bit FLAC or Apple Lossless files (24-bit AIFF and WAV) tagged `HDCD=decoded`,
with ReplayGain measured on the decode;
`--hdcd keep` encodes the audio as pressed. With `ask`, the default, `rip` asks
at a terminal (yes, except for AIFF and WAV), and `encode`
keeps the audio as pressed.

Tracks with pre-emphasis (in the TOC or the Q subchannel, as the report has
them) are de-emphasized by `--pre-emphasis deemphasize` (or the `preEmphasis`
setting), as a CD player plays them: 20-bit FLAC or Apple Lossless files (24-bit
AIFF and WAV) tagged `DE_EMPHASIZED=yes`, with ReplayGain measured on the result;
the disc's other tracks are encoded as they are. `--pre-emphasis keep` encodes
them as pressed, tagged `PRE_EMPHASIS=yes`. With `ask`, the default, `rip` asks
at a terminal (yes by default), and `encode` de-emphasizes. The CUE sheet marks
the tracks kept as pressed (`FLAGS PRE`), not the de-emphasized ones.

Tracks that are all digital silence (Nine Inch Nails *Broken* has 91, before
its hidden tracks 98 and 99) are left out by `--silent-tracks leave-out` (or the
`silentTracks` setting): no files, and no lines in the album's CUE sheet. The
other tracks keep the disc's numbers, and a disc image keeps every track.
`--silent-tracks keep` encodes them as any track. With `ask`, the default, `rip`
asks at a terminal (yes by default), and `encode` leaves them out. The rip
always reads and verifies every track.

A DTS-CD's tracks hold a DTS stream (surround sound that plays as static
without a DTS decoder), which the report names. `--dts decode` (or the `dts`
setting) encodes the album as the disc has it, the stream bit for bit, and a
decoded copy beside it, `<Album> (DTS 5.1)`; `--dts decode-only` writes the
decode alone; `--dts keep` the stream alone. With `ask`, the default, `rip`
asks at a terminal (decode by default), and `encode` keeps the stream.
Decoding needs `ffmpeg` (`brew install ffmpeg`), which Silverside runs as a
separate program (`SILVERSIDE_FFMPEG` names another, or `none`); without it,
the stream is kept. The decoded files have every channel, 20-bit in FLAC and
Apple Lossless (24-bit if the stream says its source was), in FLAC, Apple
Lossless, AAC, or AIFF (FLAC for WAV, AAC for MP3); they are gapless across
the tracks, tagged `DTS=decoded`, with ReplayGain. Every file of a DTS-CD is
tagged `MEDIA=DTS CD`. AAC and MP3 cannot keep the stream itself: a rip in
those formats writes the decode alone, or encodes nothing.

`encode -i` also takes an album folder in the library: the album is encoded
again from its lossless files, each checked against the rip's CRC-32 first.
`--hdcd-copy` writes the decode as an album of its own beside it,
`<Album> (HDCD)` (`--hdcd-copy-suffix "(HDCD AAC)"` names it otherwise); `--hdcd decode --overwrite` decodes in place, in the album's
format.

`silverside encode` (or `rip --encode`) puts the files in the library as
`Artist/Album/18-03 Title.flac` (disc 18, track 3), with every disc of a
release in one album folder, a full-size `cover.jpg`, and a CUE sheet for each
disc. On a compilation, each track's artist comes first:
`02 Mark Cromer & Jeff Briggs - Asoka`. For live shows whose
MusicBrainz disc titles have a date and venue, titles end with
`[Venue, M-D-YY]`. A segue mark (`Scarlet Begonias >`) stays in the TITLE
tag and leaves the file name; `segueMarks` in the settings changes that.
It encodes only tracks that AccurateRip or CTDB verified,
unless you give `--allow-unverified`. The rip's report goes into the album
folder too, as `Rip Report.json` (`Rip Report (Disc 1).json` for a release of several discs). Files that are already in the
library stay unless you give `--overwrite`; at a terminal, `rip --encode`
asks first. An album folder that holds a rip of another release of the same
name (another edition) is not used either, unless you give `--overwrite`:
give the album a name of its own with `silverside metadata -i <rip>
--set album="Bitches Brew [2015]"`. At a terminal, `rip --encode` asks for
one, and offers the album's name with the release's year. ReplayGain's album gain is the disc's own until every disc of a
set is in the album folder; the last disc's encoding gives every disc the
album gain over all of them. `--add-to-music` (or the `addToMusic` setting)
adds the files to Apple's Music app, in every format but FLAC; the first time,
macOS asks whether the terminal may control Music.

`--image` (or the `writeImages` setting) also writes a disc image: the whole
disc in one lossless file, in the library's format or FLAC for AAC and MP3,
with a CUE sheet from which a burner makes the disc again. It goes into the
images folder (`--images`, or the `images` setting), in folders named as the
library's: `Artist/Album/Album (Disc 2).flac` and `.cue`. The image is decoded
again and must match the rip's audio. A FLAC image also holds the CUE sheet in
its `CUESHEET` tag. Data tracks and CD+G graphics are not in it.

After `rip --encode`, a rip whose tracks are all verified and encoded is
deleted, because the library has everything. `--keep-rip` (or the
`keepRipAfterEncoding` setting) keeps the WAV files, for example as an
archive. A rip with any track that is not verified is always kept, so that
`silverside repair` can try again.

A new release is often in neither AccurateRip nor CTDB at first, and both
fill in over weeks. `silverside check` with a rip folder, or an album folder
in the library, looks each disc up again and updates its report. A match
found before is never lost, and the disc is not needed.

## Settings

The settings are a JSON file that the CLI and the app share:
`~/Library/Application Support/Silverside/settings.json` (`silverside config path`). An
option on the command line overrides its setting.

```sh
silverside config                                    # every setting
silverside config set library /Volumes/storage/Music
silverside config set format alac
silverside config set plainPunctuation true          # Walkin’ becomes Walkin'
silverside config set encodeAfterRip true
silverside config set aac.mode cbr
silverside config unset aac.mode                     # back to the default
```

| Setting | Default | |
|---|---|---|
| `library` | `~/Music/Silverside Library` | where encoded files go |
| `rips` | `~/Music/Silverside Rips` | where rips go |
| `format` | `flac` | `flac`, `alac`, `aac`, `aiff`, `wav`, or `mp3` |
| `folderTemplate` | `{albumArtist}/{album}` | the album folder, in the library |
| `trackTemplate` | `[{disc:2}-]{track} [{otherArtist} - ]{title}` | each file's name |
| `ripFolderTemplate` | `{artist} - {album}[ (Disc {disc})]` | each rip's folder |
| `liveShowStyle` | `true` | `[Venue, M-D-YY]` for live shows |
| `segueMarks` | `tags` | a title's trailing `>`: in `tags` only, `everywhere`, or `none` |
| `compilationFolder` | `""` | the folder for Various Artists releases, if not "Various Artists" |
| `plainPunctuation` | `false` | ASCII quotes and dashes in names and tags |
| `artwork` | `front` | `front`, `all`, or `none` |
| `readC2` | `true` | ask the drive for C2 error flags |
| `writeEACLog` | `true` | write `Rip Report.log` beside each report, in the layout of Exact Audio Copy's logs (`--eac-log`, `--no-eac-log`) |
| `testAndCopy` | `false` | after each track, read it once more and keep both CRC-32s in the report (`rip --test`) |
| `encodeAfterRip` | `false` | `rip` encodes when it finishes |
| `keepRipAfterEncoding` | `false` | keep the WAV files after `rip --encode` |
| `ejectAfterRip` | `false` | `rip` ejects the disc when every track is verified (`--eject`) |
| `replayGain` | `true` | ReplayGain tags: each track's gain and peak and the album's, as EBU R 128 measures them, for players that level albums, and the dynamic range (DR and loudness range, [docs/DynamicRange.md](DynamicRange.md)); the audio is not changed (`encode --no-replay-gain`) |
| `addToMusic` | `false` | add the encoded files to the Music app, except FLAC (`--add-to-music`) |
| `ripOnInsert` | `false` | the app rips a disc when it goes in, if its release is certain and it is not ripped yet |
| `hdcd` | `ask` | for a disc whose HDCD codes ask for peak extend or a gain: `decode` into 20-bit files (24-bit AIFF and WAV), `keep` as pressed, or `ask` (`--hdcd`) |
| `preEmphasis` | `ask` | for tracks with pre-emphasis: `deemphasize` into 20-bit files (24-bit AIFF and WAV), `keep` as pressed, or `ask` (`--pre-emphasis`) |
| `silentTracks` | `ask` | for tracks that are all digital silence: `leave-out` (no files; the other tracks keep the disc's numbers), `keep`, or `ask` (`--silent-tracks`) |
| `dts` | `ask` | for a DTS-CD: `decode` (the stream, and a decoded copy beside it), `decode-only`, `keep` the stream, or `ask` (`--dts`); decoding needs ffmpeg |
| `dataTracks` | `ask` | for a disc with a data track (an Enhanced CD's extras): `save` it as an ISO image, copied into the album folder as `Data track.iso` with its files in a `Data track` folder; `skip` it; or `ask` at a terminal, saving otherwise (`rip --data-tracks`) |
| `cdGraphicsVideo` | `ask` | for a disc with CD+G graphics: make a video of them after the rip with `appleLossless` or `aac` audio, make `none`, or `ask` at a terminal, making none otherwise (`rip --video`) |
| `cdGraphicsVideoPictures` | `eg` | for a disc with CD+EG graphics: the video in 256 colors (`eg`), in 16 as a CD+G player shows it (`g`), or `both` (`rip --picture`) |
| `writeImages` | `false` | also write a disc image when a disc is encoded (`--image`) |
| `images` | `~/Music/Silverside Images` | the folder for disc images (`--images`) |
| `aac.mode`, `aac.bitRate`, `aac.vbrQuality` | `vbr-constrained`, `256`, `127` | Apple's AAC encoder |
| `mp3.mode`, `mp3.vbrQuality`, `mp3.bitRate`, `mp3.extraArguments` | `vbr`, `0`, `320`, `[]` | LAME |

In templates, fields are in braces: `artist`, `albumArtist`, `album`, `date`,
`year`, `disc`, `discs`, `discTitle`, `track`, `title`, `trackArtist`, and
`otherArtist` (the track's artist, only when it is not the album's).
`{disc:2}` pads a number to two digits. A part in brackets is kept only when
all its fields have values, so `[{disc:2}-]` is left out for a single disc, and
`/` makes a subfolder.

## Drives and offsets

Every drive reads audio a few samples early or late: its read offset. Silverside
finds it in AccurateRip's list of drives, then confirms it from your own rips
(two discs that agree). `silverside drives -d <drive> --set-offset N` sets it by hand, with or without a disc.
`silverside drives -d <drive> --measure-cache` measures, with a disc in the drive, how much the drive caches, so
re-reads empty the cache with fewer reads.

## MP3 options

`--mp3-mode`, `--mp3-quality`, `--mp3-bitrate`, and `--lame-option` (on
`encode` and `rip --encode`) override the `mp3.*` settings. MP3 needs LAME;
see [Encoding to MP3](../README.md#encoding-to-mp3) in the README.
