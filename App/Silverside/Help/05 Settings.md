# Settings

Silverside and the `silverside` command line share one settings file, so a change in either applies to both.

## General

- **Music library** is where encoded albums go, in folders named by the Naming settings.
- **Rips** is where each rip's WAV files, report, and cover go. Keep it out of the library: music apps would import the WAV files.
- **After a rip:** encode the disc into the library in the chosen format; keep or delete the rip's WAV files once the album is encoded and verified; add the files to the Music app; eject the disc when every track is verified. MP3 is in the list of formats once the LAME encoder is installed (see Encoding).
- **Add the files to the Music app** works for every format but FLAC, which Music cannot read. Music adds the files where they are, in the library folder, or copies them into its own folder if "Copy files to Music Media folder when adding to Library" is on in Music's settings. The first time, macOS asks whether Silverside may control Music; the answer is in System Settings › Privacy & Security › Automation. A file renamed later by Update the Library or a name change stays in Music, which follows a moved file on the same disk.
- **When a disc goes in, rip it at once:** a disc that goes in while Silverside runs is ripped five seconds after its lookup, if MusicBrainz names its release for certain (an exact match, and not one of several releases unless you chose one for the set) and the disc is not ripped yet. The status bar counts down, with Rip Now and Cancel. Otherwise the disc waits for you, and the status bar says why. A disc already in a drive when Silverside starts is never ripped by itself. With eject after the rip on as well, a set rips with no more than a swap of discs.
- **Artwork:** the front cover only (saved as `cover.jpg` and embedded in the files), every image in the Cover Art Archive, or none.

## Ripping

C2 error flags are a drive's own report of sectors it had trouble with. Silverside re-reads them first. The flags are a hint only; the reads decide.

**Test and copy** reads each track once more after its rip, and keeps the CRC-32 of both reads in the report, as Exact Audio Copy does. It is off by default: the rip already compares reads of every doubtful sector, and the test read takes as long as another read of the disc. Turn it on for a record that EAC's users will recognize.

**Save an Enhanced CD's data track** keeps the extras for a computer that some CDs have after the music, as `Data track.iso` in the album's folder (see Ripping a Disc › Enhanced CDs). It is on by default, and costs about a minute and the track's size, often 50 to 600 MB.

## Encoding

FLAC, Apple Lossless, AIFF, and WAV are lossless and have no options. AAC takes a bit rate mode, bit rate, and VBR quality.

MP3 needs LAME, a free encoder that Silverside runs as a separate program, because Apple's frameworks cannot write MP3. Install it with Homebrew (brew.sh), in Terminal:

```
brew install lame
```

Until LAME is installed, MP3 is missing from the formats in General and in the welcome, and the MP3 options here are dimmed. Silverside looks for LAME every few seconds while Settings or the welcome is open, so MP3 turns on as soon as the install ends. The options are lame's: a variable bit rate from a quality (0 is the best, about 245 kbit/s), or a constant or average bit rate.

Every encoded file is decoded again and compared with the rip before it goes into the library.

### ReplayGain

Albums are mastered at different levels, so one is quiet and the next is loud. ReplayGain tags tell a player how much to turn each one up or down to play them at the same level. Silverside measures each track and the whole album as the broadcast standard EBU R 128 does, and writes the result into the files as five tags: the track's gain and peak, the album's gain and peak, and the reference level (−18 LUFS). The audio itself is not changed, in any format, and the tags can be removed with any tag editor. The rip report lists the values.

For a set of several discs, the album is the whole set, as a player sees it: every disc has the same album name. Until every disc is in the library, each disc's album gain is its own; when the last disc is encoded, the files of every disc get the album gain over all of them, so a show split across discs does not jump in level at a disc change.

What the tags do depends on the player:

- The Music app and iTunes ignore them. They have their own leveling, Sound Check, which they measure themselves.
- Most other players read them (foobar2000, VLC, mpv, Plexamp, the Navidrome and Jellyfin apps, most Android players), but most keep the leveling off until you turn it on in their settings. Then they offer two modes: **album** gain keeps an album's own dynamics, so a quiet intro stays quiet next to the loud song after it, and only levels one album against another; **track** gain levels every track, which suits shuffle. Silverside writes both, so the choice is the player's.

The setting is on by default because the tags cost nothing until a player uses them, and adding them to a library later means measuring every file again with another program. Turn it off if you would rather have no such tags in your files.

### HDCD

What to do with a disc whose HDCD codes ask for peak extend or gain: **Ask each time** (the default), **Decode** (20-bit FLAC and Apple Lossless, 24-bit AIFF and WAV), or **Keep as pressed** (files bit for bit the disc). A disc whose codes ask for nothing is always kept as pressed. See HDCD under Ripping a Disc.

### Pre-emphasis

What to do with tracks mastered with pre-emphasis: **Ask each time** (the default), **De-emphasize** (as a CD player plays them: 20-bit FLAC and Apple Lossless, 24-bit AIFF and WAV), or **Keep as pressed** (files bit for bit the disc). See Pre-emphasis and other flags under Ripping a Disc.

### Disc image

With **Also write a disc image** on, each disc that is encoded is also written as one file, with a CUE sheet: the image. A burner (such as cdrdao) can make the disc again from it, and some players (foobar2000, for one) show its tracks. The image is lossless: in the library's format, or FLAC when the library is AAC or MP3. It goes into the images folder, in folders named as the library's, and the album's tracks are written as usual. Like every file, it is decoded again and compared with the rip. A FLAC image also holds its CUE sheet in its tags.

An image holds the audio only: a data track (on an Enhanced CD or a game disc) and CD+G graphics are not in it. An image is not renamed or retagged when you change an album's names later.

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
