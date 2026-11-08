# Dynamic range

## What it is

Many CDs from the late 1990s on were mastered loud: the loud parts were limited
and compressed so that the whole album plays near full scale (the "loudness
war"). Silverside measures how much room each track has, in two ways, in the
same pass over the audio as ReplayGain:

- **DR**, the number of the DR meter and the Dynamic Range Database ("DR12"):
  how far the loudest peaks rise above the loudest parts, in dB. A
  hard-limited master has a low DR (DR5), an open one a high DR (DR14).
- **Loudness range** (LRA, EBU Tech 3342): how far the loudness moves between
  the quiet and the loud parts, in LU. A quiet piece with a loud end has a
  wide range even when its peaks are limited, so the two numbers say
  different things.

The rip report lists both for each track and for the disc, and for a set of
several discs, over the whole set. The files get four tags:

| Tag | Value |
|---|---|
| `DYNAMIC RANGE` | the track's DR, a whole number, as foobar2000's DR meter writes it |
| `ALBUM DYNAMIC RANGE` | the disc's DR: the mean of its tracks' whole numbers, rounded, as the DR meter groups an album by disc |
| `REPLAYGAIN_TRACK_RANGE` | the track's loudness range, "5.20 dB", as loudgain writes it |
| `REPLAYGAIN_ALBUM_RANGE` | the album's loudness range, over the whole set as the album gain is |

Players ignore these tags. Tag editors and library tools (foobar2000, Kid3,
beets) show them. The values are measured with ReplayGain, so the setting
`replayGain` (Settings › Encoding) turns them on and off too. A decoded HDCD,
de-emphasized, or DTS-decoded track is measured as the files hold it: an HDCD
decode with peak extend has a higher DR than the disc as pressed.

## How it is measured

Both are Silverside's own code (`DynamicRange.swift`, with the ReplayGain meter
in `Loudness.swift`).

**DR** follows Algorithmix's description of the measurement ("Measuring DR",
version 1.3, 2009): each channel in blocks of 132,480 samples (3 seconds at
44.1 kHz); each block's RMS, times √2 so that a sine's RMS equals its peak, and
its peak. A channel's DR is its second-highest block peak over the RMS of its
loudest 20% of blocks (at least one); a track's is the mean of its channels'.
The DR meter's own program was not available to compare with, and the
description leaves two details open: how 20% of the blocks rounds (Silverside
rounds up), and how an album's value is found (Silverside takes the mean of the
tracks' whole numbers).

**Loudness range** uses the BS.1770 K-weighting of the ReplayGain meter:
3-second windows every 100 ms, the absolute gate at −70 LUFS, the relative gate
20 LU under the mean, and the range from the 10th percentile to the 95th, as
Tech 3342's reference code takes them. For a set, each disc keeps a histogram
of its windows in 0.1 LU steps, so the set's range needs no other disc's audio.

## How it was checked (2026-11-08)

**Against ffmpeg.** ffmpeg's `drmeter` and `ebur128` filters are separate
implementations. 250 tracks chosen at random from the library were measured
with both, from their FLAC files:

| | Silverside − ffmpeg |
|---|---|
| Loudness range, 242 tracks | −0.015 LU on average; at most 0.23 LU |
| DR, 221 tracks of music (the test discs left out) | at most 0.31 dB; 11 whole numbers differ, where the value is near a half |

ffmpeg prints the loudness range to 0.1 LU, from a histogram in 0.1 LU steps.
Its DR blocks are 3 seconds exactly (132,300 samples), so their edges fall
elsewhere, which moves the value a little. On test tones, ffmpeg's DR is 3 or
6 dB higher than the description gives: a steady sine has DR 0 by the
description (its peak equals its RMS times √2), and Silverside reads 0.00.

**EBU Tech 3342.** The standard's first three test signals (a 1 kHz sine, 20
seconds at one level, then 20 at another: −20 and −30 dBFS, −20 and −15, −40
and −20) read 10, 5, and 20 LU, within the 1 LU the standard allows
(`DynamicRangeTests`).

**Unit tests** (`DynamicRangeTests`): the second-highest peak, not the highest,
sets the DR, and the loudest 20% of blocks set the RMS; an album's DR is the
mean of its tracks' whole numbers; a disc's histogram gives the same range as
its windows, within 0.1 LU; the tags.
