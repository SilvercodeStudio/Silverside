# Settings

Silverside and the `silverside` command line share one settings file, so a change in either applies to both.

## General

- **Music library** is where encoded albums go, in folders named by the Naming settings.
- **Rips** is where each rip's WAV files, report, and cover go. Keep it out of the library: music apps would import the WAV files.
- **After a rip:** encode the disc into the library in the chosen format; keep or delete the rip's WAV files once the album is encoded and verified; eject the disc when every track is verified.
- **Artwork:** the front cover only (saved as `cover.jpg` and embedded in the files), every image in the Cover Art Archive, or none.

## Ripping

C2 error flags are a drive's own report of sectors it had trouble with. Silverside re-reads them first. The flags are a hint only; the reads decide.

## Encoding

FLAC, Apple Lossless, AIFF, and WAV are lossless and have no options. AAC takes a bit rate mode, bit rate, and VBR quality. MP3 needs the `lame` program on the Mac, which Silverside runs as a separate program; it takes lame's modes and VBR quality.

Every encoded file is decoded again and compared with the rip before it goes into the library.

## Naming

Templates name the album folder and the track files in the library, and the rip's folder. The fields:

| Field | Value |
|---|---|
| `{artist}`, `{albumArtist}` | The release's artist. |
| `{album}` | The release's title. |
| `{year}`, `{date}` | The release date. |
| `{disc}`, `{discs}` | The disc's number in a set, and the set's size. `{disc:2}` pads to two digits. |
| `{discTitle}` | The disc's own title, if it has one. |
| `{track}`, `{title}` | The track's number and title. |
| `{trackArtist}` | The track's artist. |
| `{otherArtist}` | The track's artist, only when it is not the album's. |

A part in square brackets is left out when its field is empty, so `[{disc:2}-]{track} {title}` gives `03 Title` on a single disc and `02-03 Title` in a set.

The styles, each with an example in the window:

- **Live shows** adds `[Venue, date]` to titles when every disc of the release is a dated show, and tags each disc with the show's date.
- **Segue marks**: MusicBrainz ends a title with `>` when the song runs into the next. The mark can stay in the tags only (the default: `China Cat Sunflower >` in the tag, `04-01 China Cat Sunflower.flac` on disk), in the tags and the file names, or go.
- **Compilations folder**: a release credited to Various Artists is tagged COMPILATION, and each track's file name carries its own artist. The album folder is named Various Artists unless you give another name here.
- **Plain punctuation** turns typographic quotes and dashes into ASCII in names and tags.
