# Pre-emphasis

## What it is

Pre-emphasis is a type of noise reduction from the first years of the Compact
Disc. The mastering boosts the treble, up to about 10 dB in the highest
frequencies, and a CD player cuts it by the same amount when it plays
(de-emphasis). The curve is in the CD standard (IEC 60908): time constants of
50 µs and 15 µs. Better converters soon made it unnecessary, so it is rare, and
almost no disc made after the mid-1980s uses it.

A disc marks it for each track, in its table of contents, in its subchannel
(the Q frames beside the audio), or in both; the flag is not in the audio
itself. A ripper that ignores it makes files that still have the boost, and
players play them too bright. Silverside reads both places while it rips, and
for those tracks Settings › Encoding (`preEmphasis` for the command line)
chooses:

- **De-emphasize:** the audio as a CD player plays it, in 20-bit FLAC and Apple
  Lossless (24-bit AIFF and WAV), tagged `DE_EMPHASIZED=yes`. The disc's other
  tracks stay bit for bit as pressed.
- **Keep as pressed:** files bit for bit the disc, tagged `PRE_EMPHASIS=yes`, and
  marked `FLAGS PRE` in the CUE sheet.

A disc image always keeps the disc as pressed. See the app's help, Ripping a
Disc › Pre-emphasis and other flags, for more.

The filter is Silverside's own (`PreEmphasis.swift`): a first-order filter whose
pole and zero are fitted to the analog curve at 44.1 kHz. Its impulse response is
all positive and sums to 1, so it cannot clip. A track that follows a
de-emphasized track starts with the filter settled by that track's end, so
gapless audio has no step.

## How it was checked

**The curve.** The filter follows the analog curve within 0.08 dB from 20 Hz to
20 kHz; a filter made by the bilinear transform, the usual method, is 0.97 dB off
at 20 kHz. ffmpeg's `aemphasis` (`type=cd`, `mode=reproduction`) is not a
reference: measured with sines, it is set to 0 dB at 1 kHz (the curve is
−0.37 dB there), and at 20 kHz it is 4.3 dB under the curve.

**A real disc (2026-10-26).** The *Denon Audio Technical CD* (38C39-7147) has
pre-emphasis in the Q frames of the 23 tracks with "(Emphasis)" in their titles,
and in none of its TOC entries, so a ripper that reads only the TOC misses it.
Silverside finds exactly those 23 tracks. The disc has the same test signals
with and without pre-emphasis, so the result can be checked:

- The de-emphasized 20 Hz to 20 kHz sweeps (tracks 38 and 39) match the plain
  sweeps (36 and 37) within 0.15 dB. As pressed, they rise to +9.2 dB.
- The de-emphasized 1 kHz tones (28 and 29) come out 0.36 dB under the plain
  ones (18 and 19), as the curve says.
- Listening in Petrichor, the as-pressed and de-emphasized versions are easy to
  tell apart, most of all on the jazz track and the spoken announcements.

Rips in two drives (MATSHITA and ASUS) gave the same audio. Both are 97 of 99
accurate in AccurateRip (it keeps no checksum for the two silent tracks) and
verified by CTDB. An upload of the disc to the Internet Archive has all 99
tracks bit for bit as pressed, 6 samples later than Silverside's, with nothing
to say that 23 of them need de-emphasis.

**20 bits.** De-emphasized audio uses all its low bits, so FLAC cannot drop
them. Rounded to 20 bits, the error is near −120 dBFS, about 20 dB under the
16-bit source's own noise; 24 bits would store 4 more bits of noise.

**Unit tests** (`PreEmphasisTests`): the curve within 0.1 dB from 20 Hz to
20 kHz; sines lowered by the curve; rounding to 20 bits without clipping; a
track that continues from the track before equals both as one; the tags; only
the flagged tracks change; Keep as pressed is bit for bit.

## Known limits

- A file runs from its track's index 01 to the next track's, so it ends with the
  next track's pregap, and that pregap follows this track's flag. On the Denon
  disc, every pregap where the flag changes is digital silence, which
  de-emphasis does not change.
