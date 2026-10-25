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
silverside info -d disk14                 # the disc: tracks, ISRCs, disc IDs
silverside rip -d disk14                  # rip to WAV, verify, repair
silverside rip -d disk14 --encode         # rip, then encode into the library
silverside encode -i "<rip folder>"       # encode a rip later
```

`silverside help <command>` explains each command, with examples.

## Commands

| Command | What it does |
|---|---|
| `drives` | Lists the drives, their discs, read offsets, and caches. Sets a drive's offset by hand (`--set-offset`), measures its cache (`--measure-cache`), or writes a drive report for a bug report (`--report`). |
| `info` | Shows a disc's TOC, pregaps, ISRCs, MCN, CD-Text, disc IDs, and whether AccurateRip and CTDB have it. |
| `cdtext` | Shows every field of a disc's CD-Text, in each of its languages, or its raw packs (`--packs`). |
| `rip` | Rips a disc to WAV files: verifies, re-reads, repairs, looks up the release, saves the cover, and can encode. |
| `repair` | Repairs rips again with CTDB: pools rips from several drives, and re-reads with the disc in a drive. |
| `metadata` | Shows the MusicBrainz releases for a disc, and keeps the chosen one in a rip's `disc.json`; `--set` edits names, `--cover` gives a cover, and `--retag` writes both into the album's encoded files. |
| `encode` | Encodes rips into the library, named and tagged, and checks each file. |
| `hdcd` | Looks for HDCD codes in audio files and folders (WAV, AIFF, FLAC, Apple Lossless), such as rips and albums from before. |
| `config` | Shows and changes the settings. |
| `eject` | Ejects the disc from a drive (`-d diskN`), or from every drive (`--all`). |
| `license` | Shows the license, and the code from others that the CLI includes. |

## What a rip makes

A rip's folder is in `~/Music/Silverside Rips` (the `rips` setting), named from the
release, such as `Grateful Dead - Cornell 5-8-77 (Disc 1)`, and holds:

- `Track 01.wav` and so on: one file for each track, from its index 01 to the
  next track's (a pregap belongs to the track before it)
- `disc.json`: the rip report, with the TOC and the MusicBrainz release, and
  after `rip --encode`, the encoding: the format, the encoder and its settings,
  and each track's file (the album folder's `Rip Report (Disc N).json` has it too)
- `cover.jpg`, and `Artwork/` with `--artwork all`
- `Track NN.suspects`, for tracks that are not verified: the other values that
  reads gave for their suspect samples, for a later `silverside repair`
- `Rip Report.md`, and `Track 00.wav` if the disc has hidden track one audio

The report also says whether the tracks have HDCD codes, and what they ask of
a decoder (peak extend, a gain adjustment, or nothing), and the encoded files
of such a disc are tagged `MEDIA=HDCD`. For a disc whose codes
ask for something, `--hdcd decode` (or the `hdcd` setting) decodes them into
20-bit FLAC or Apple Lossless files (24-bit AIFF and WAV) tagged `HDCD=decoded`,
with ReplayGain measured on the decode;
`--hdcd keep` encodes the audio as pressed. With `ask`, the default, `rip` asks
at a terminal (yes, except for AIFF and WAV), and `encode`
keeps the audio as pressed.

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
folder too, as `Rip Report (Disc 1).json`. Files that are already in the
library stay unless you give `--overwrite`; at a terminal, `rip --encode`
asks first. ReplayGain's album gain is the disc's own until every disc of a
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
| `testAndCopy` | `false` | after each track, read it once more and keep both CRC-32s in the report (`rip --test`) |
| `encodeAfterRip` | `false` | `rip` encodes when it finishes |
| `keepRipAfterEncoding` | `false` | keep the WAV files after `rip --encode` |
| `ejectAfterRip` | `false` | `rip` ejects the disc when every track is verified |
| `replayGain` | `true` | ReplayGain tags: each track's gain and peak and the album's, as EBU R 128 measures them, for players that level albums; the audio is not changed (`encode --no-replay-gain`) |
| `addToMusic` | `false` | add the encoded files to the Music app, except FLAC (`--add-to-music`) |
| `ripOnInsert` | `false` | the app rips a disc when it goes in, if its release is certain and it is not ripped yet |
| `hdcd` | `ask` | for a disc whose HDCD codes ask for peak extend or a gain: `decode` into 20-bit files (24-bit AIFF and WAV), `keep` as pressed, or `ask` (`--hdcd`) |
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
(two discs that agree). `silverside drives -d diskN --set-offset N` sets it by hand.
`silverside drives -d diskN --measure-cache` measures how much the drive caches, so
re-reads empty the cache with fewer reads.

## MP3 options

`--mp3-mode`, `--mp3-quality`, `--mp3-bitrate`, and `--lame-option` (on
`encode` and `rip --encode`) override the `mp3.*` settings. MP3 needs LAME;
see [Encoding to MP3](../README.md#encoding-to-mp3) in the README.
