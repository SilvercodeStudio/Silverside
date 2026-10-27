# ReplayGain

## What it is

Albums are mastered at different levels, so one is quiet and the next is loud.
ReplayGain tags tell a player how much to turn each one up or down to play them
at the same level. Silverside measures each track and the whole album as the
broadcast standard EBU R 128 (ITU-R BS.1770) does, and writes five tags: the
track's gain and peak, the album's gain and peak, and the reference level
(−18 LUFS). The audio itself is not changed, in any format.

For a set of several discs, the album is the whole set: when the last disc is
encoded, every disc gets the album gain over all of them, so a show split across
discs does not jump in level at a disc change.

The Music app ignores the tags and uses its own Sound Check. Most other players
read them, usually once you turn leveling on, in album or track mode. The
setting is in Settings › Encoding (`replayGain` for the command line), and on by
default. See the app's help, Settings › ReplayGain, for more.

The meter is Silverside's own code (`Loudness.swift`): K-weighting with the
filter constants derived for 44.1 kHz as libebur128 does, 400 ms blocks every
100 ms, and the absolute (−70 LUFS) and relative (−10 LU) gates. The peak is the
sample peak, as ReplayGain tags expect, not the true peak. A decoded HDCD or
de-emphasized track is measured after decoding, as the files hold it.

## How it was checked (2026-10-27)

**Against ffmpeg.** ffmpeg's `ebur128` filter is a separate implementation of
the same standard. Every album in the library with ReplayGain records was
measured with it from its FLAC files, and compared with the values in its
`Rip Report.json`: 17 discs and 363 tracks, among them HDCD-decoded *Dozin' at
the Knick*, the 20-bit de-emphasized *Denon Audio Technical CD* (full-scale
sines, −63 LUFS tones, silent tracks), and four releases of two or three discs.

| | Silverside − ffmpeg |
|---|---|
| Track loudness, 363 tracks | +0.005 LU on average; at most 0.022 LU |
| Album loudness, 17 discs | +0.004 to +0.010 LU |
| Release loudness, all discs of 4 sets | +0.004 to +0.007 LU |
| Sample peak | the same (`astats` confirms the values that `ebur128` prints rounded) |

EBU Tech 3341 allows 0.1 LU. The small bias, under 0.01 LU, is most likely
ffmpeg's: it finds the integrated loudness from a histogram in 0.01 LU steps.
The tags round the gain to 0.01 dB.

To measure an album whose files mix 16-bit and 20-bit FLAC (a partly
de-emphasized disc) in one stream, use ffmpeg's `concat` filter, not the concat
demuxer: the demuxer cannot join files of different bit depths, and gave a
loudness 9.6 LU off.

**EBU Tech 3341.** The standard's five stereo test signals (1 kHz sines), made
with ffmpeg as 16-bit WAV files:

| Case | Expected | Silverside | ffmpeg |
|---|---|---|---|
| 1: −23 dBFS | −23.0 ±0.1 | −22.991 | −23.000 |
| 2: −33 dBFS | −33.0 ±0.1 | −32.990 | −33.000 |
| 3: −36, −23, −36 dBFS | −23.0 ±0.1 | −23.011 | −23.021 |
| 4: −72, −36, −23, −36, −72 dBFS | −23.0 ±0.1 | −23.011 | −23.021 |
| 5: −26, −20, −26 dBFS | −23.0 ±0.1 | −22.976 | −22.985 |

Cases 3 to 5 test the gates.

**Unit tests** (`LoudnessTests`): a −23 dBFS sine reads −23.0 LUFS and a
full-scale sine 0; silence and audio under 400 ms have no loudness; Tech 3341's
third case; an album is one gating over every track's blocks; a release of
several discs is the same from the discs' saved histograms.

## Known limits

- The peak in the tags of AAC and MP3 files is the source's. A lossy decode can
  go a little higher, up to about 1 dB. A player uses the peak only to keep from
  clipping when it raises the level.
