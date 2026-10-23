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
| `cdtext` | Shows every field of a disc's CD-Text, or its raw packs (`--packs`). |
| `rip` | Rips a disc to WAV files: verifies, re-reads, repairs, looks up the release, saves the cover, and can encode. |
| `repair` | Repairs rips again with CTDB: pools rips from several drives, and re-reads with the disc in a drive. |
| `metadata` | Shows the MusicBrainz releases for a disc, and keeps the chosen one in a rip's `disc.json`. |
| `encode` | Encodes rips into the library, named and tagged, and checks each file. |
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
asks first.

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
| `encodeAfterRip` | `false` | `rip` encodes when it finishes |
| `keepRipAfterEncoding` | `false` | keep the WAV files after `rip --encode` |
| `ejectAfterRip` | `false` | `rip` ejects the disc when every track is verified |
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
