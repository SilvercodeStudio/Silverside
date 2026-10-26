# Ripping a Disc

## Metadata

When a disc appears, Silverside reads its table of contents and asks MusicBrainz which releases have it. The chip under the album name says how sure the match is:

| Chip | Meaning |
|---|---|
| Disc ID match | MusicBrainz knows this exact disc. |
| Nearly the same TOC | MusicBrainz does not know the disc ID, but these releases have almost the same track lengths. Check the release, and consider adding the disc ID to MusicBrainz: click the chip (an earlier rip shows it too) or use the link in the release picker. You need a MusicBrainz account. |
| Several releases match | More than one release has the disc, and Silverside cannot tell which. Choose one. The choice is kept for the other discs of the set. |
| Not in MusicBrainz | No release has the disc. The names come from the disc's CD-Text, or you type them in the header and the track table. The files get those names, but no MusicBrainz IDs. |

Other Releases shows every release that matches. A disc with CD-Text gets a switch between the MusicBrainz names and the names on the disc. The switch only changes what you see: the rip's tags come from MusicBrainz. To tag the rip with the disc's names, show them and click Use These Names. They become your edits to the MusicBrainz names, so you can still change them before the rip, and Undo Edits goes back. An album name from CD-Text is an album edit, so the other discs of a set get it too. A disc can have CD-Text in several languages, such as Japanese and English: Silverside shows the one in your Mac's language if the disc has it, else the disc's first.

The cover comes from the Cover Art Archive: the image that MusicBrainz editors marked as the release's main front. The archive often has more, such as the art of the digital release or, in a box set, each disc's sleeve. A badge with a count in the cover's corner says how many there are: click it (or right-click the cover and choose Cover Art Archive…) to see them all and use another. A sleeve whose comment names the disc is marked "This disc". For a disc that has none there, or a better scan of your own, drop an image file on the cover, or right-click it and choose Choose Cover. It is saved with the rip and embedded in the files. JPEG and PNG are kept as they are; other formats become JPEG. Click a cover to see it at full size in Quick Look (with no cover yet, a click chooses one). To keep a copy of any cover, drag it out to the Finder, or right-click it and choose Export Cover.

The info button at the end of a track's row shows everything known about the track: the artist, the composers and lyricists when MusicBrainz names them (with the name in your language beside one in another script), the album's genre, the length, the ISRC from the disc, and the MusicBrainz recording ID. All of it goes into the files' tags, and for an earlier rip that was encoded, the button also shows the tags in the file itself. The info button beside the header's chips shows the release (date, country, status, barcode, labels, release group, discs) and the disc's own codes (the disc IDs, MCN, CD-Text, media type). The album, the artist, and each track's title and artist can be edited; the rest comes from MusicBrainz as it is.

## Playing a track

The play button at the start of a track's row plays it from the disc, read the way a rip reads it, so a track that plays is one the drive can read. A bar at the bottom of the window shows the track, with pause, a slider to move within it, and stop. An earlier rip's tracks play the same way, from the rip's WAV files or the encoded files in the library. One track plays at a time; starting a rip, a repair, or a drive test on the drive stops it.

## Sets

A release with several CDs is a set. Its discs share the album's names, the release choice, and the cover: a change on one disc reaches the others. The sidebar's Sets section, or the "discs ripped" chip on a disc, opens the set: each disc's state (still to do, ripped but not verified, verified but not in the library, done), when and on which drive it was ripped, the album's names to edit (press Return to keep a change), and the cover. Click the arrow at a disc's row to see its tracks and their results; Show, or a double-click, opens the disc, and the Back arrow in the toolbar (⌘[ or ⌘←) returns to the set. **Encode Discs** encodes the verified discs that are not in the library yet, as Settings say. **Update the Library** writes the set's names and cover into every encoded disc's files, renames the files and the album folder as the naming templates say, and writes the CUE sheets again; the audio is not touched. A box set's DVD or Blu-ray is not counted as a disc to rip.

With ReplayGain on (Settings › Encoding), each disc is measured when it is encoded, and until the set is complete, each disc's album gain is its own. When the last disc is encoded, Silverside measures the whole set as one album and writes that album gain into every disc's files, so a show split across discs plays at one level. Nothing needs to be done for it; the set view shows the album gain over all the discs, and each disc's own. Update the Library writes it again if it is missing, for example for discs encoded by an older version.

## Changing the cover

Before a rip, drop an image on the cover, or choose one from its menu (your own file, or another of the Cover Art Archive's images), in place of the archive's main front; the cover's menu puts the archive's back. After a rip, the same works on the rip in Recent Rips: the new cover goes into the rip's folder, into the album folder in the library, and into the tags of the encoded files, and the audio is not touched. A cover you choose is kept for the release, so the other discs of a box set get it, and so does a later rip of the same release.

### A sleeve for each disc

Some box sets have art for each part: *Summer Magic 1985* has a sleeve for each show, and the archive's editors note which discs each one is for ("Mediums 1–2"). When they have, the picker offers **Use Each Disc's Sleeve**, and says which discs take which sleeve. The choice is kept for the release: the discs ripped so far, encoded or not, get their sleeves at once, and a disc you put in later shows its own before the rip, with nothing to choose. Each disc's files embed its sleeve, kept as "cover (Disc 2).jpg" beside the set's cover.jpg, which stays the album folder's cover. A disc that no sleeve names keeps the set's cover. Choosing one cover for the set, or Use the Cover Art Archive's, ends it.

## Changing an earlier rip

An earlier rip's track titles and artists can be edited in its track table, as before a rip; a track's menu adds an artist or clears its edits. A moment after a change, the encoded files take the new names and are renamed as the naming templates say; files whose names did not change are not touched. A rip that is not encoded yet keeps the names for its encoding. The album's names of a set are edited in the set's view.

A rip that is not encoded has an **Encode** button, which encodes it into the library as Settings say. Only a verified rip is encoded; see Verification for what to try with one that is not.

## Read modes

- **Secure** reads each track once and checks it against AccurateRip. A track that does not match is read again, and the sectors that read differently are re-read until two reads agree. Then the whole disc is checked against the CUETools database and, if it still has errors, repaired with that database's repair data. Use Secure unless you have a reason not to.
- **Fast** reads each track once. It is for clean discs when time matters, or to see what a drive makes of a disc before a secure rip.

## Options for one rip

The Options button in the toolbar holds choices for the next rip only:

- **Folder.** By default a rip's folder is named from the release, in the rips folder. Choose another for this rip.
- **Pool earlier rips of this disc.** On by default when the rips folder has a rip of the same disc. A track that an earlier rip got accurate replaces one that is not, and where the rips disagree, the CTDB repair has more versions to work with.
- **Offline.** No AccurateRip, CTDB, or drive offset list. The names come from the lookup already made. Repair (see Verification) can check the rip later.

The Secure or Fast choice is kept between launches.

## While it rips

The status column shows each track's progress: the read, later reads (up to four in all, until two agree), and rounds of re-reads of the sectors that differ (up to sixteen). The status bar shows the whole rip, the drive's speed, and the time left. Under it, a graph shows the whole disc by position, each track to scale: a bar marks sectors with trouble, and its height is how many of the sectors at that spot are marked. Dim orange is a sector the drive flagged, orange one that reads disagreed on and then settled, blue one that never agreed but CTDB fixed, and red one that never agreed or could not be read. The line is the read under way. Hold the pointer over a track for its numbers.

Behind another app, the Dock icon shows a progress bar, and when the rip is done, the icon bounces and a notification says how it went (macOS asks once whether Silverside may send notifications).

Stop ends the rip after the read under way. The tracks ripped so far stay in the folder, and a later rip of the same disc can use them.

## HDCD

HDCD (High Definition Compatible Digital) discs were mastered to hold more than a 16-bit CD can, and still play in every CD player. The mastering hides control codes in the lowest bit of the audio. Only a player with an HDCD decoder reads them, and they can ask it for two changes:

- **Peak extend:** the loudest peaks were compressed by up to 9 dB to fit on the disc. The decoder expands them again.
- **Gain:** passages were raised by up to 7.5 dB to fit on the disc. The decoder lowers them again, and their finest detail goes below the 16 bits that a CD holds.

Without a decoder, you hear the disc as pressed: the peaks stay compressed, and the raised passages stay raised. Few players have a decoder.

### What Silverside finds

The HDCD logo on a disc, or HDCD codes in its audio, does not mean that the disc uses peak extend or gain. Many discs were mastered with HDCD equipment, which puts the codes in the audio, but on most of them the codes ask for nothing. A decoder then plays the disc exactly as a player without one does. So Silverside offers to decode only a disc whose codes ask for peak extend or gain, and never one with the logo alone.

Silverside looks for the codes in every track it rips, and the header and the result show the HDCD logo with what it found:

- **codes only:** the codes ask for nothing, so a decoder plays the same audio, and there is nothing to decode. Most discs with the logo are like this.
- **peak extend** or **gain:** a decoder changes the audio. These discs are worth decoding.

Before the rip, the logo with "per MusicBrainz" means that MusicBrainz lists the disc as HDCD. The rip decides: some discs with the logo have no codes, and some without it have them. The report lists the codes of each track. For rips from before, `silverside hdcd` looks for the codes in WAV, FLAC, AIFF, and Apple Lossless files.

### Decode, or keep as pressed

When a disc's codes ask for peak extend or gain, Silverside asks before it encodes, and recommends Decode for every format but AIFF and WAV. Settings › Encoding can give one answer for every disc.

- **Decode** gives the audio as an HDCD player plays it. FLAC and Apple Lossless files are 20-bit, so they keep the detail that the decoder puts below 16 bits; AIFF and WAV files are 24-bit. For AAC and MP3, decode now or never: a lossy encode removes the codes, so a lossy file of the disc as pressed can never be decoded.
- **Keep as pressed** makes files that are bit for bit the disc, with the codes still in them. Nothing is lost: Decode HDCD… can make a decoded copy at any time, and a few players decode such files as they play them. This is the usual choice for AIFF and WAV.

Decoded files:

- **are about 6 dB quieter** than the disc, because the decoder leaves room for the peaks that it expands. ReplayGain, measured on the decoded audio, sets the level again in players that read it.
- **are larger** in lossless formats: about 5% for FLAC, a third for Apple Lossless, and half again for AIFF and WAV. AAC and MP3 files are no larger.
- **are tagged** `HDCD=decoded`. Every file of a disc with HDCD codes, decoded or not, is tagged `MEDIA=HDCD`.

In a set, a disc whose codes ask for nothing is decoded too when another disc of the set is, so that every disc plays at one level. Its decode is the same audio, 6 dB quieter.

HDCD was made to carry 20 bits. In tests, 24-bit files held almost nothing more, far below what you can hear, and were larger: 8% for FLAC, 30% for Apple Lossless. The decoder is the one in FFmpeg (`ffmpeg -af hdcd`).

### Decode an earlier rip

**Decode HDCD…** in an earlier rip's toolbar decodes it later, into any format:

- **Beside the album:** a copy with its own folder and album title, such as "Dozin' at the Knick (HDCD)", so that players list both. You can change the part after the title, such as "(HDCD AAC)" for a second copy.
- **In place:** the album's files become the decoded files.

Silverside decodes from the rip's WAV files. If they are gone, it uses the album's lossless files, and first checks each one against the CRC-32 of the verified rip.

## Where the files go

Each rip gets a folder in the rips folder (Settings › General), named from the release: the WAV files, `disc.json` and `Rip Report.md` with every detail, and the cover. With "Encode the disc into the library" on, the album is encoded into the library after the rip, with the cover, the report, and a CUE sheet in its folder; the files carry the names and credits from MusicBrainz, and ReplayGain loudness tags unless Settings › Encoding turns them off. Then a rip whose tracks are all verified and encoded is deleted, unless you keep it. Settings › Encoding can also write a disc image of each disc: the whole disc in one file, with a CUE sheet.
