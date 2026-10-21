# CDRip.app

This is a CD ripping app for macOS intended to produce secure,
verified rips of audio CDs similar to Exact Audio Copy (EAC) for
Windows. It extracts the audio from CDs into a folder of your choice
in a highly accurate manner with an extraction report, and can optionally
encode the tracks to the format of your choice such as FLAC, Apple
Lossless, AAC, WAV, or (with a helper app) MP3, as well as tag
the tracks with appropriate metadata (song and album titles.)

Today it is a command-line tool, `cdrip`. The Mac app comes next.

## Requirements

It requires an Apple Silicon or Intel Mac, running macOS 15 (Sequoia)
or later, and a CD drive (or a compatible CD/DVD/BD drive), and of
course some audio CDs that you want to rip.

Any drive that macOS sees as a CD drive works, however it is connected.
No Mac that runs macOS 15 came with a built-in optical drive, so in
practice the drive is external: USB (tested with three drives),
Thunderbolt, or a SATA drive in an enclosure.

Encoding to MP3 requires an [external CLI encoder app](#encoding-to-mp3)
to be installed. All other supported formats are handled natively.

## Features

- **Accurate rips.** Each track is read with the drive's read offset corrected,
  and checked against [AccurateRip](http://www.accuraterip.com) and the
  [CUETools database](http://cue.tools/wiki/CUETools_Database) (CTDB), which
  hold checksums from other people's rips of the same disc.
- **Secure re-reads.** A track that does not match is read again. Sectors that
  read differently, that the drive flags with C2 errors, or that cannot be
  read at all are re-read until their data matches or the re-reads give up.
- **Repair.** A disc with errors is repaired with CTDB's repair data, and the
  repaired tracks are checked against AccurateRip again.
- **Metadata from [MusicBrainz](https://musicbrainz.org)**, and cover art from
  the [Cover Art Archive](https://coverartarchive.org): front covers, and
  back covers and booklets if you want them.
- **Encoding** to FLAC, Apple Lossless (ALAC), AAC, AIFF, WAV, or MP3, with
  tags and the cover embedded. Each file is checked after encoding: a
  lossless file must decode to exactly the ripped audio.
- **A rip report** (`disc.json`) with every track's result, the TOC, the disc
  IDs, the ISRCs and MCN, the drive and its offset, and the release.

### Ripping marginal CDs

Note that it will take longer to rip a marginal CD than a nice
defect-free CD (no major scratches, gouges, disc rot, etc).

Using a different drive might help.

Tips:

- **Clean the disc first.** Light cleaning helped several discs in testing.
- **Let the rip finish.** A damaged track can take several minutes: the
  status line shows each read, the sectors with C2 errors, and the rounds of
  re-reads. Most damaged discs that were tested came out fully accurate from
  one rip, after the CTDB repair.
- **Try another drive.** Drives differ in how many versions of a damaged
  sector they return, and more versions help the repair. A disc that one
  drive could not finish was repaired from one rip in another.
- **Pool rips from several drives.** Rip the disc in a second drive with
  `--pool` and the first rip's folder: an accurate track from either rip is
  used, and the other versions join the repair.
- **Keep the rip.** Each rip keeps its suspect samples next to its WAV files,
  so `cdrip repair` can try again later, with more rips or more re-reads.
- **Some discs cannot be repaired.** When too much of a disc is damaged (a
  scratch across many tracks, or damage to the reflective layer), the tracks
  that verify are still marked as verified, and the others are not.

### Encoding to MP3

Apple's audio frameworks cannot write MP3, so CDRip uses the free
[LAME](https://lame.sourceforge.io) encoder for it. Install it with
[Homebrew](https://brew.sh):

```sh
brew install lame
```

CDRip finds `lame` on your `PATH` (or in `/opt/homebrew/bin` or
`/usr/local/bin`), sends it the audio, and writes the tags itself. By default
it uses LAME's best variable bit rate (`-V 0`, about 245 kbit/s); see
`--mp3-mode`, `--mp3-quality`, `--mp3-bitrate`, and `--lame-option`.

## CLI app

### Install

From a copy of this repository, with Xcode installed:

```sh
make install                    # cdrip in /usr/local/bin (may need sudo)
make install PREFIX=~/.local    # or in ~/.local/bin
```

`make install` builds `cdrip` for Apple silicon and Intel, and installs shell
completions for zsh, bash, and fish. `make uninstall` takes them away.

### Quick start

```sh
cdrip drives                         # the drives, and the disc in each
cdrip info -d disk14                 # the disc: tracks, ISRCs, disc IDs
cdrip rip -d disk14                  # rip to WAV, verify, repair
cdrip rip -d disk14 --encode         # rip, then encode into the library
cdrip encode -i "<rip folder>"       # encode a rip later
```

`cdrip help <command>` explains each command, with examples.

### Commands

| Command | What it does |
|---|---|
| `drives` | Lists the drives, their discs, read offsets, and caches. Sets a drive's offset by hand (`--set-offset`), or measures its cache (`--measure-cache`). |
| `info` | Shows a disc's TOC, pregaps, ISRCs, MCN, disc IDs, and whether AccurateRip and CTDB have it. |
| `rip` | Rips a disc to WAV files: verifies, re-reads, repairs, looks up the release, saves the cover, and can encode. |
| `repair` | Repairs rips again with CTDB: pools rips from several drives, and re-reads with the disc in a drive. |
| `metadata` | Shows the MusicBrainz releases for a disc, and keeps the chosen one in a rip's `disc.json`. |
| `encode` | Encodes rips into the library, named and tagged, and checks each file. |
| `config` | Shows and changes the settings. |

### What a rip makes

A rip's folder is in `~/Music/CDRip Rips` (the `rips` setting), named from the
release, such as `Grateful Dead - Cornell 5-8-77 (Disc 1)`, and holds:

- `Track 01.wav` and so on: one file for each track, from its index 01 to the
  next track's (a pregap belongs to the track before it)
- `disc.json`: the rip report, with the TOC and the MusicBrainz release
- `cover.jpg`, and `Artwork/` with `--artwork all`
- `Track NN.suspects`, for tracks that are not verified: the other values that
  reads gave for their suspect samples, for a later `cdrip repair`

`cdrip encode` (or `rip --encode`) puts the files in the library as
`Artist/Album/18-03 Title.flac` (disc 18, track 3), with every disc of a
release in one album folder, and a full-size `cover.jpg`. For live shows whose
MusicBrainz disc titles have a date and venue, titles end with
`[Venue, M-D-YY]`. It encodes only tracks that AccurateRip or CTDB verified,
unless you give `--allow-unverified`. The rip's report goes into the album
folder too, as `Rip Report (Disc 1).json`.

After `rip --encode`, a rip whose tracks are all verified and encoded is
deleted, because the library has everything. `--keep-rip` (or the
`keepRipAfterEncoding` setting) keeps the WAV files, for example as an
archive. A rip with any track that is not verified is always kept, so that
`cdrip repair` can try again.

### Settings

The settings are a JSON file that the CLI and the app share:
`~/Library/Application Support/CDRip/settings.json` (`cdrip config path`). An
option on the command line overrides its setting.

```sh
cdrip config                                    # every setting
cdrip config set library /Volumes/storage/Music
cdrip config set format alac
cdrip config set plainPunctuation true          # Walkin’ becomes Walkin'
cdrip config set encodeAfterRip true
cdrip config set aac.mode cbr
cdrip config unset aac.mode                     # back to the default
```

| Setting | Default | |
|---|---|---|
| `library` | `~/Music/CDRip Library` | where encoded files go |
| `rips` | `~/Music/CDRip Rips` | where rips go |
| `format` | `flac` | `flac`, `alac`, `aac`, `aiff`, `wav`, or `mp3` |
| `folderTemplate` | `{albumArtist}/{album}` | the album folder, in the library |
| `trackTemplate` | `[{disc:2}-]{track} {title}` | each file's name |
| `ripFolderTemplate` | `{artist} - {album}[ (Disc {disc})]` | each rip's folder |
| `liveShowStyle` | `true` | `[Venue, M-D-YY]` for live shows |
| `plainPunctuation` | `false` | ASCII quotes and dashes in names and tags |
| `artwork` | `front` | `front`, `all`, or `none` |
| `readC2` | `true` | ask the drive for C2 error flags |
| `encodeAfterRip` | `false` | `rip` encodes when it finishes |
| `keepRipAfterEncoding` | `false` | keep the WAV files after `rip --encode` |
| `aac.mode`, `aac.bitRate`, `aac.vbrQuality` | `vbr-constrained`, `256`, `127` | Apple's AAC encoder |
| `mp3.mode`, `mp3.vbrQuality`, `mp3.bitRate`, `mp3.extraArguments` | `vbr`, `0`, `320`, `[]` | LAME |

In templates, fields are in braces: `artist`, `albumArtist`, `album`, `date`,
`year`, `disc`, `discs`, `discTitle`, `track`, `title`, `trackArtist`.
`{disc:2}` pads a number to two digits. A part in brackets is kept only when
all its fields have values, so `[{disc:2}-]` is left out for a single disc, and
`/` makes a subfolder.

### Drives and offsets

Every drive reads audio a few samples early or late: its read offset. CDRip
finds it in AccurateRip's list of drives, then confirms it from your own rips
(two discs that agree). `cdrip drives -d diskN --set-offset N` sets it by hand.
`cdrip drives -d diskN --measure-cache` measures how much the drive caches, so
re-reads empty the cache with fewer reads.

### MusicBrainz

CDRip looks up each disc in MusicBrainz once, waits between requests, and
keeps the answers in a cache, as MusicBrainz asks of programs that use it. When
MusicBrainz does not know a disc's ID, `rip` finds the release by its track
lengths, and prints a link to add the disc ID to MusicBrainz. When several
releases have the disc (such as a show and a box set that holds it), `rip`
asks which one, and remembers the answer for the other discs.

### Building

```sh
make test          # the engine's tests
make cli ARGS=...  # build and run cdrip from the source
make build         # the Mac app
```

Open `CDRip.xcworkspace` in Xcode for the app, the engine, and the CLI.

## TODO

See [docs/Milestones.md](docs/Milestones.md) for the plan.
