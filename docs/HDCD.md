# HDCD

## What it is

HDCD (High Definition Compatible Digital) discs were mastered to hold more
dynamic range than a 16-bit CD, and still play in every CD player. The mastering
hides control codes in the lowest bit of the audio. Only a player with an HDCD
decoder reads them, and they can ask for two changes:

- **Peak extend:** the loudest peaks were compressed by up to 9 dB to fit on the
  disc. The decoder expands them again.
- **Gain:** passages were raised by up to 7.5 dB. The decoder lowers them again,
  and their finest detail goes below the 16 bits that a CD holds.

Most discs with the HDCD logo have codes that ask for neither. They play the
same in any player, and Silverside keeps them as pressed. For a disc whose codes
do ask, Settings › Encoding (`hdcd` for the command line) chooses:

- **Decode:** the audio as an HDCD player plays it: 20-bit FLAC and Apple
  Lossless (24-bit AIFF and WAV), tagged `HDCD=decoded`, about 6 dB quieter,
  which ReplayGain makes up. FLAC files are about 5% larger, Apple Lossless
  files about 30%.
- **Keep as pressed:** files bit for bit the disc, with the codes in them, which
  can be decoded later (Decode HDCD… in the app, `silverside encode --hdcd`).

Every file of a disc with codes is tagged `MEDIA=HDCD`. See the app's help,
Ripping a Disc › HDCD, for more.

The decoder is FFmpeg's (`af_hdcd.c`, BSD license), vendored in
`SilversideKit/Vendor/HDCD` with only the filter glue replaced. Silverside rips
and verifies the disc as pressed, and decodes only when it encodes.

Note that many discs have HDCD logos and/or the main flag enabled on the disc,
but don't use the peak extend or gain features. These will be ripped exactly as
mastered on disc with no extra processing. These titles may still benefit from
the overall HDCD mastering process, which includes psychoacoustic noise shaping
similar to Sony's Super Bit Mapping, that works on standard 16-bit players.

## How it was checked

**Detection, against `ffmpeg -af hdcd` (2026-10-23).** Every track of *Cornell
5/8/77*, *Madison Square Garden 3/9/81*, and *Saint of Circumstance* (42 tracks)
has codes, and Silverside counts the same packets and damaged codes as FFmpeg on
every one. None asks for peak extend or gain: decoding gives each sample × 32768,
the same audio. Nine other Grateful Dead albums have no codes.

**A disc that uses the features (2026-10-24).** *Dozin' at the Knick* disc 1
(GDCD 4025): peak extend in every packet of all 9 tracks, and gain down to
−4.0 dB in places. The packet counts match FFmpeg on all 9 tracks. Measured from
FFmpeg's decode, only 0.06% to 0.28% of samples are above the peak-extend level
(−3.1 dBFS), and decoding raises them 3.7 to 4.5 dB against the rest.

**The decode, against FFmpeg, across whole discs (2026-10-27).** Silverside
decodes a track at a time, and starts each one with the last 5 seconds of the
track before, as a player that plays the disc straight through has them. All
three discs of *Dozin' at the Knick* (about 3 hours, 28 tracks) were decoded
this way, and by `ffmpeg -af hdcd` as one stream each. Cut to 24 bits, the two
are identical in every value of every disc.

Without the 5 seconds, the decoder starts each track reset. On these discs that
changed one track of 25 that follow another (disc 3, track 7): its first 64 ms,
by at most −89.4 dBFS, about one 16-bit step.

**20 bits.** On *Dozin'* disc 1, 0.53% of the decoded samples use the bits below
20, and cutting them leaves an error of at most −115 dBFS, under the 16-bit
source's own noise. As 24-bit FLAC the disc grew from 442 to 504 MB; at 20 bits,
to 466 MB. Apple Lossless: 447, 747, and 575 MB. The 20-bit files play in
Petrichor, VLC, and the Music app.

**Unit tests** (`HDCDTests`): codes that ask for nothing, peak extend and gain in
both packet types, damaged packets, plain audio; a decode that continues from
the track before equals the decode of both tracks as one; 20-bit FLAC; a copy
beside the album, and a decode in place that changes nothing until every track
is checked.
