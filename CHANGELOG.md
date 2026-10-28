# Changelog

What changed in each version of Silverside, the app and the `silverside`
command-line tool.

## 0.9 (not released yet)

### Added

- **Index points:** some discs, most often classical ones, mark parts of a
  track with index 02, 03, and so on. A rip finds them in the subchannel it
  already reads with the audio, and the CUE sheet, the report, and the log
  have them, so the disc can be burned again with them.
- A pregap that cannot be found, because the subchannel near the track's
  start cannot be read (a scratch can do that), shows as "unknown" in the
  report and the log, instead of as no pregap.
- An earlier rip's album, album artist, and date can be edited in its
  header, as its track titles already could. Press Return to keep a change:
  the files take the new names then, not while a name is half typed (track
  titles too). The names are kept for the release, and the sidebar and Rip
  History show them. A set's are still edited in the set's view. When two
  editions were encoded into one album folder, renaming one moves only its
  own files, and the other keeps its folder, report, and CUE sheet.
- **Accept a rip as it is:** an earlier rip that is not verified can be
  encoded with Encode…, after you accept it. It goes into the library as a
  verified rip does, and its report and an "Accepted as it is" chip say which
  tracks are not verified.
- A disc you ripped before shows a "Ripped before" chip in its header, which
  says whether that rip is verified and opens it when clicked.
- **Move to Trash…** for an earlier rip, from its menu in Recent Rips and Rip
  History: the rip's folder with its WAV files, or for a rip in the library, its
  report, encoded files, CUE sheet, and disc image. Files that another rip in
  the same album folder uses stay.
- **New Release in MusicBrainz** (Disc menu, and the release picker): for a
  disc that MusicBrainz has only as part of another release, such as the
  single-disc edition of a set's first disc. It opens MusicBrainz's release
  editor with a new release copied from that one (release group, names,
  recordings, labels) and this disc's track lengths and disc ID, but not the
  other edition's barcode or catalog numbers.
- **Add to MusicBrainz:** a disc that MusicBrainz does not know has an "Add to
  MusicBrainz…" chip, before the rip and on the earlier rip. It opens
  MusicBrainz's release editor in the browser with the names you typed, the
  track lengths, and the disc's TOC filled in, so the disc ID is attached when
  you submit the release.
- **Enhanced CDs:** the data track after the music, with extras for a computer,
  is saved as an ISO disc image and copied into the album folder as
  `Data track.iso`, with its files copied out beside it into a `Data track`
  folder, where the pictures, videos, and pages open as they are. The image
  holds the track exactly; its file system counts from the start of the disc,
  so it does not open by itself, and the report says where it starts. The
  first rip of such a disc asks whether to save it, with "use this answer for
  every disc" (Settings › Ripping, `dataTracks`, or `rip --data-tracks`). A
  chip in the header shows a disc with a data track.
- When MusicBrainz has a disc's ID on another release only, but a release you
  ripped other discs of has a disc with the same track lengths, a chip asks
  "Disc 2 of your 4-disc Vegas 96?". A click opens MusicBrainz's page that adds
  the disc ID to that release. This finds a set's other edition, and a disc ID
  that someone added to the wrong release.
- On an Enhanced CD, a drive that can read past the end of the music (the
  MATSHITA can) reads the last track to its end, instead of leaving its last
  few samples silent.
- The report says when the first or last few samples of the disc's audio are
  silence because the drive cannot read past its edge. With the read offset,
  those samples come from past the edge; AccurateRip and CTDB do not check them.
- **The rip history keeps every rip**, in a folder of its own beside the
  settings, so a rip stays in Rip History after its album is moved out of the
  library (to a NAS) or deleted, marked "Moved or deleted", with its report and
  graph. Look for Moved Rips… finds the albums in a folder you choose; Remove
  from History forgets one. The About window's counts include them. The rips
  you have now go into it the first time the app looks through your folders.
- `silverside drives` names the disc in each drive when MusicBrainz knew it at
  an earlier lookup, from the cache, so it waits for no request.

### Changed

- The track table is quieter. Green marks only each track's result; AccurateRip
  and CTDB show their match as a check mark and the number of rips that agree.
  The Repaired column is gone, and Re-reads is hidden at first: a short line
  under the track's result says how many sectors were re-read and how many
  samples CTDB repaired. Control-click the column headings to show the Re-reads column again,
  or to hide AccurateRip, CTDB, or Encoding; the table keeps your choice.
- An earlier rip's report pane is hidden at first, and stays shown or hidden as
  you leave it.
- Track and disc info is shorter: a file's tags and the disc's IDs fold away
  under their headings, and a long list scrolls.
- Settings › Encoding shows the options of the chosen format only, at the top.
- While a track is read again, the sidebar says "Reading track 6 again"
  instead of a percent that stands at 100%, and it shows the encoding's own
  progress while the album is encoded.
- The AccurateRip chip counts tracks that match another pressing with the
  others: "AccurateRip 12 / 13 · other pressing", not "AccurateRip 0 / 13" and
  a second chip. A sector whose re-reads never agreed, on a rip that CTDB
  verified as it was, is "confirmed by CTDB", not "fixed".
- The "Disc ID match" chip names the release when you point to it (its media,
  such as CD + Blu-ray, label, country, and date), and a click opens the
  release in MusicBrainz. "Several releases match" opens the release picker.
  The picker names media other than plain CDs, and a release with a disc that
  is not a CD says so in its disc chip: "Disc 1 of 2 · CD + Blu-ray".
- `silverside metadata --cover` takes any image that macOS reads, such as WebP
  or HEIC, and makes it a JPEG, as the app does. JPEG and PNG stay as they
  are. In the app, Choose Cover offers only such images, and a file dropped on
  the cover that cannot be used, such as an SVG drawing, gets a message
  instead of no change.

### Fixed

- A repair that could fix only some tracks could change a track that
  AccurateRip had already matched, and make it wrong. With a CTDB entry from
  another pressing, the check of a track also covers the end of the track
  before it, and a correction there was kept without proof. Now a correction
  is kept only where a track check covers it, and a track that AccurateRip
  matches is never changed. The repair log says "7 entries", not "7 entrys".
- After an encode deletes a rip's WAV files, the rip's folder goes too. A cover
  or artwork that the rip found in its folder already, or that a later change
  of cover wrote there, stayed behind with the folder; now each such file goes
  when the album folder has the same file. Files of your own stay.
- A track whose re-reads never agreed on a sector, on a rip that CTDB then
  verified as it was, stayed "not accurate" in AccurateRip, though its audio
  was right. It is now checked again, at another pressing's offset too, as a
  CD-R copy needs.
- The rips folder at the foot of the sidebar no longer overlaps the last item
  of a long list.
- A disc with no audio, such as a game or program CD, showed as "Audio CD ·
  0 tracks" with an empty track list. It now shows as a data disc, in the app
  and in `silverside drives`.
- Look Up Metadata asks MusicBrainz again. It used the answer kept from the
  last lookup, so a disc just added to MusicBrainz stayed "Not in
  MusicBrainz" for up to a day.

## 0.8 (2026-10-27)

### Added

- **De-emphasis:** a track mastered with pre-emphasis, a treble boost that a
  CD player takes out again, can now be encoded as a CD player plays it. The
  tracks become 20-bit FLAC or Apple Lossless files (24-bit AIFF and WAV),
  tagged DE_EMPHASIZED=yes, with ReplayGain measured on the result; the other
  tracks of the disc stay bit for bit as pressed. The app asks before it
  encodes such a disc and advises De-emphasize; Settings › Encoding can give
  one answer for every disc. Kept as pressed, the tracks are tagged
  PRE_EMPHASIS=yes. The tags are written in every format. The CUE sheet marks
  the tracks kept as pressed (`FLAGS PRE`), not the de-emphasized ones, so that
  a player does not take the boost out twice. `silverside` has
  `--pre-emphasis` and the `preEmphasis` setting. A disc image always keeps
  the disc as pressed, with its CUE sheet's marks.
- Pre-emphasis is found in the disc's subchannel as well as its table of
  contents. Some discs set it in one place only: the Denon Audio Technical CD
  marks 23 tracks in the subchannel and none in the table of contents. The
  rip reads the subchannel with the audio, at no cost in time on the drives
  tested. A rip with pre-emphasis shows a chip.
- The rip log and the report list each track's control bits: pre-emphasis,
  digital copy permitted, and four-channel audio, and say whether each came
  from the table of contents, the subchannel, or both. Four-channel audio is
  in early versions of the CD standard, but no released disc is known to use
  it (the 1999 edition gives the bit to broadcasting); a disc that
  sets it gets a chip of its own. `silverside info` shows the subchannel's
  flags too.
- The About window, the rip log, and the reports name the Git commit that
  Silverside was built from, with "-dirty" when the build had changes that were
  not committed: "Silverside 0.8 (536e697-dirty)". The About window shows the
  build number too, and leaves out the commit in a release, which its Git tag
  names. `silverside --version` shows the commit when `make` built it.

### Changed

- A new app icon: a disc and the arm of its reader, on warm paper, with a
  dark brown version for the dark icon style.
- Settings › Encoding explains ReplayGain, HDCD, and pre-emphasis in fewer
  words; Help has the details.
- The Rip button has the new rip icon. During a rip, level bars hang from the
  top and bounce behind the arm, the laser's spot pulses, and a line in the
  progress bar's colors fills around the edge. It floats over the lower right
  of the track list, so the list has more room; the last tracks scroll out
  from under it.
- The About window and the welcome show the icon on warm paper in light mode
  and on dark brown in dark mode, to match the new icon, in place of dark blue.
- The "nearly the same TOC" chip opens the MusicBrainz page that adds the
  disc's ID to its release, and its tooltip says what the match means. An
  earlier rip that MusicBrainz matched by its track lengths shows the chip
  too, so its disc ID can be added without the disc.

### Fixed

- An album renamed into a folder that already held it lost its own copy of
  each file that the other folder also had. Now the files move only when no
  two of them differ; otherwise the update stops and names the file in the way.
- Encoding stops when two tracks would get the same file name, also names
  that differ only in case or accents, instead of one file replacing the other.
- Rips of the same disc in two drives at once wrote into one folder. Now the
  second rip gets a folder of its own. A rip that stopped in a crash can still
  go on in its folder.
- A repair that verified the disc with tracks from an earlier rip marked the
  first rip's folder as verified, though its files were not the verified
  audio. Now it writes the "… repaired" folder. A repair's report also has the
  checksums and AccurateRip results of the repaired audio.
- Encoding and Check Again check each WAV file against the rip's length and
  checksum, as they already did for FLAC and Apple Lossless files, so a WAV
  file changed after the rip is not taken as verified.
- A re-read that could have come from the drive's cache no longer counts as a
  read that agrees. This happens only when no cache flush can be made away
  from the sectors, as with a short track on a disc with little other audio.
  The report and the log say so. A track longer than the cache needs no
  flush: its own read empties the cache.
- When sectors before track 1 cannot be read, and the rest is silence, the
  report and the log say so: some drives cannot read there, and another drive
  may find a hidden track. A hidden track with unreadable sectors is not
  verified.
- A drive or USB bridge that refuses the C2 flags or the subchannel with an
  I/O error no longer makes good sectors unreadable: Silverside reads them
  without. A damaged sector does not count as a refusal once the drive has
  given the flags or the subchannel. Reads with them fit a USB bridge's 64 KB
  limit. A part of a track read without the flags does not lose the flags that
  the drive gave for the rest of it.
- Damaged CD-Text no longer moves the titles after the damage onto the wrong
  tracks.
- A decoded HDCD track started with the decoder reset, so until the track's
  first code, often 50 ms in, its peaks were not extended and the disc's gain
  adjustment was not applied. Now the end of the track before sets the
  decoder, as in a player that plays the disc straight through, so gapless
  albums have no change at the track boundaries. Albums decoded before keep
  the error until they are decoded again from the rip.
- Encoding a rip of only some tracks lost every track but one from the CUE
  sheet and the report's list of files. Decoding HDCD in place of such an
  album, or of one with a hidden track before track 1, could put one track's
  audio in another track's file.
- A rip pooled with earlier rips could be verified by CTDB while its files
  kept the drive's own read, which differed. CTDB checks the version that most
  rips agree on, and now that version is what the rip saves, with its checksums.
- Decoding HDCD in place of an album, with disc images on, decoded the album
  and then failed: the image was made from the decoded files. The originals
  now stay until the image is written. A WAV album, too, keeps every original
  until all its new files are written, so a failure leaves it as it was.
- Encoding an album in place through a symbolic link now protects its source
  tracks and report. If its disc image cannot be written, the original album
  stays unchanged and can be tried again after fixing the image destination.
- An album renamed or retagged after the rip lost the pre-emphasis and
  copy-permitted marks from its CUE sheet.
- A track that AccurateRip keeps no checksum for, such as a silent one, shows
  "No checksum" instead of "Not accurate", is not counted in the AccurateRip
  chip, and gets two reads instead of four. Check Again corrects an earlier
  rip, and it is now offered for a rip with tracks AccurateRip did not match,
  even when CTDB verified the disc.
- The area under the disc graph no longer gets a little shorter while the
  pointer is over a track.
- A disc that MusicBrainz knows no longer becomes "Unknown Album" when
  MusicBrainz is busy. If the release's own lookup fails after the disc's
  lookup found it, the disc keeps the release's names, without the writers
  and the genre, and the rip log says so.

## 0.7 (2026-10-25)

### Added

- **HDCD recognition:** each track of a rip is checked for HDCD codes. The
  header and the result show the HDCD logo, with "codes only" when the codes
  ask for nothing (a decoder would play the same audio, as on most discs with
  the logo), or "peak extend" or "gain" when an HDCD decoder would change the
  audio. Before the rip, the logo shows when MusicBrainz lists the disc as
  HDCD. The report has an HDCD table for each track, and the encoded files
  of a disc with HDCD codes are tagged `MEDIA=HDCD`, as MusicBrainz names
  the medium.
- About › Acknowledgments and `silverside license` credit FFmpeg's HDCD
  decoder, which Silverside includes under its BSD license.
- `silverside hdcd` looks for HDCD codes in audio files and folders, such as
  rips and albums from before.
- **HDCD decoding**, as an option: a disc whose codes ask for peak extend or a
  gain adjustment can be decoded into 20-bit FLAC or Apple Lossless files
  (HDCD's own resolution; 24-bit for AIFF and WAV) tagged `HDCD=decoded`, with
  ReplayGain measured on the decode. The app asks before it encodes such a
  disc, and advises decoding, except for AIFF and WAV, whose 24-bit files are
  half again as large; Settings › Encoding can answer for every disc (`hdcd`:
  ask, decode, keep; `--hdcd` on the command line). In a set, a disc whose
  codes ask for nothing is decoded too when another disc is, so that the
  discs play at one level. **Decode HDCD…** on an earlier rip makes a decoded
  copy beside the album, as "<Album> (HDCD)" or another name you give, or
  decodes in place of its files, even after the rip's WAV files are gone; in
  place, no file is replaced until every track is decoded and checked.
- `silverside encode` takes an album folder in the library as its input,
  encoding it again from its lossless files, each checked against the rip's
  CRC-32; `--hdcd-copy` writes the decoded copy beside it.

- **Disc images,** off by default (Settings › Encoding, `writeImages`, or
  `--image` on the command line): each disc that is encoded is also written as
  one lossless file with a CUE sheet, from which a burner can make the disc
  again. It goes into a folder of its own (`~/Music/Silverside Images`, named as
  the library's albums), in the library's format, or FLAC when the library is
  AAC or MP3, and is checked against the rip like every file.
- **Choose among the Cover Art Archive's images.** Cover Art Archive… in a
  cover's menu (before a rip, on an earlier rip, and in a set) shows every
  image the archive has for the release, with its type and comment, and uses
  the one you pick, for every disc of a set. Silverside still takes the main
  front by itself, but a release can have better ones, such as a digital
  release's art or a box set's sleeves; a sleeve whose comment names the disc
  is marked "This disc". A badge with the count of images, in the corner of a
  cover, opens it too.
- **A sleeve for each disc of a box set,** when the archive's editors noted
  which discs each sleeve is for (such as *Summer Magic 1985*, with one for
  each show): Use Each Disc's Sleeve gives every disc its own, in the discs
  ripped so far and in the ones ripped later, which show theirs before the rip.
  Each disc's files embed its sleeve; the album folder keeps the set's cover.
- **CD-Text in every language a disc has.** A disc can carry CD-Text in up to
  eight languages, and Japanese discs write it in MS-JIS (Shift-JIS). Silverside
  reads every block, uses the one in your Mac's language if the disc has it
  (else the first), and keeps the others in the report; `silverside cdtext`
  shows them all. Before, only the first block was read, and Japanese text came
  out garbled.

- **Check Again** looks an earlier rip up in AccurateRip and CTDB again, for
  a new release that they did not have at the time of the rip, and checks
  the rip's audio against them: its WAV files, or the album's FLAC or Apple
  Lossless files. The disc is not needed. A set's toolbar has it for every
  disc that can use it, and `silverside check` does the same in a terminal.
- **Use These Names** tags a rip with the disc's CD-Text in place of the
  MusicBrainz names. Show the CD-Text names, click it, and the names become
  edits that you can still change before the rip.

### Changed

- A set's view says where its ReplayGain stands: the album gain over every
  disc once the last disc is encoded (with each disc's own beside it), or how
  many discs are still to be encoded before then.
- A click on a cover shows it at full size in Quick Look, and the cover's
  menu has Quick Look too. Choose Cover… is in the menu; a click still
  chooses one where there is no cover yet.
- The AccurateRip and CTDB columns say in a tooltip what their numbers count.
- The welcome window is shorter, so it fits on a 13-inch MacBook's screen.
- The chips under a disc's names, and after a rip, wrap onto more rows in a
  narrow window. Before, they pushed the album's fields past the window's
  edge, or scrolled out of sight. "Names from" moves above its picker when
  there is no room beside it, in place of one letter to a line.

## 0.6 (2026-10-23)

### Added

- **Play a track** to check it: a play button on each track of the disc in a
  drive, read as a rip reads it, and on each track of an earlier rip, from its
  WAV file or its encoded file. A bar at the bottom of the window has pause,
  a position slider, and stop. One track plays at a time, and a rip or a repair
  on the drive stops it.
- **Track info and disc info:** an info button at the end of each track's
  row shows what MusicBrainz knows of the track (artist, composers, lyricists,
  the album's genre, the recording ID) with the disc's ISRC and, for an
  earlier rip, its checksums and the tags in its encoded file, as a player
  reads them. A disc info button in the header, and in an earlier rip's
  toolbar, shows the release (date, country, status, barcode, labels, release
  group, discs, cover art) and the disc (its IDs, MCN, CD-Text, media type,
  pre-emphasis). The genre shows as a chip in the header. The app looks the
  chosen release up in full when the disc goes in, so all of it is there
  before the rip, and the rip sends no request of its own.
- A composer or lyricist whose name MusicBrainz has in another script, such as
  Արամ Խաչատրյան, is tagged with the name in your language (Aram Khachaturian)
  and shown with both. The report keeps both.
- The Markdown report's track table has a Composer column when MusicBrainz
  names one, and its Disc table the genre.
- **Rip a disc when it goes in** (Settings › General): when MusicBrainz names
  the disc's release for certain and the disc is not ripped yet, the rip
  starts after five seconds, with Rip Now and Cancel in the status bar.
  Otherwise the status bar says why the disc waits for you.
- **Add the files to the Music app** after encoding (Settings › General, or
  `--add-to-music` on `rip` and `encode`), in every format but FLAC, which
  Music cannot read. Music adds them where they are, or copies them if its own
  settings say so. macOS asks once whether Silverside may control Music.
- **Edit an earlier rip's track titles and artists,** in its track table, as
  before a rip. A moment after a change, the encoded files take the new names
  and are renamed; the other files are not touched.
- An earlier rip that is not encoded has an **Encode** button.

### Changed

- **The CTDB check is many times faster.** Its checksums use the system's
  CRC-32, which is the slow part of checking a disc stored at another
  pressing's alignment, and the search for the alignment and the repair of
  the columns run on every core. The status bar says what the check is doing,
  and the log names each entry's shift.
- **Sets.** A multi-disc release among the earlier rips has a view of its own,
  from the sidebar's Sets section or the set chip on a disc: each disc's state
  (still to do, ripped, verified, encoded), the album's names, which every
  disc shares, and its cover. Encode Discs puts the verified discs that are
  not in the library yet there, and Update the Library writes the names and
  the cover into every encoded disc's files, renames the files and the album
  folder as the templates say, and writes the CUE sheets again. The set's
  summary now tells a disc that is ripped but not verified or not encoded
  from one that is done, and a box set's DVD is not counted as a disc to rip.
  A disc that MusicBrainz lists only by its track lengths gets the release
  chosen for the set's other discs. Open a disc's row to see its tracks and
  their results, with each disc's time; double-click a row to show that disc.
- **Back and Forward** arrows in the toolbar, as in a browser: after Show
  takes you from a set to one of its discs, Back takes you to the set again.
  The keys are ⌘[ and ⌘], or ⌘← and ⌘→ when you are not typing in a field.
- **Change the cover after a rip.** Drop an image on an earlier rip's cover,
  or choose one from its menu, and it goes into the rip's folder, the album
  folder, and the tags of the encoded files; the audio is not touched. The
  menu can also put the Cover Art Archive's cover back. A cover you choose is
  kept for the release, so the other discs of a set, and a later rip of the
  same release, get it. `silverside metadata --cover x.jpg --retag` does the
  same from the terminal.
- **ReplayGain tags,** on by default: each track's gain and peak, and the
  album's, measured as EBU R 128 does, written into every format, and listed
  in the rip report. Settings › Encoding, or `encode --no-replay-gain`. For a
  set, the album is the whole set: once every disc is in the library, every
  disc's files get the album gain over all of them, so a show split across
  discs plays at one level.
- **Tracks encode in parallel,** up to four at a time (half the Mac's cores,
  at least two), each still checked against the rip before it goes into the
  library.
- **The log and the report keep the times.** Each line of the rip's log starts
  with the time, so it says when each track, the CTDB check, and the encoding
  finished, and the last line says how long the rip took. The report says when
  the rip started, how long the tracks took (and the longest), the CTDB check,
  the whole rip, and the encoding.
- A later read of a track says how many there can be ("read 2 of up to 4"),
  and the time left says "plus re-reads" while a track is read again.
- Update the Library, and a name changed after a rip, write only the FLAC and
  Apple Lossless or AAC files whose tags change, which matters for a library
  on a network volume.

### Fixed

- An earlier rip's track table showed the names from MusicBrainz, not the
  ones you had edited before the rip.
- The cover art was downloaded after the last track, while the status bar said
  only "Finishing the rip", and with "every image" chosen a release's
  full-size scans could take a minute. The download now runs while the disc
  is read, and the status bar says when the rip is still waiting for it.
- In 0.5, MusicBrainz refused every disc lookup ("lookup failed" for each disc),
  because the lookup asked for relationships that only a release lookup may
  have. The disc lookup is as it was, and a rip looks the chosen release up
  once more for the composers.

## 0.5 (2026-10-23)

### Added

- **Checksums in the rip report:** each track's CRC-32 as Exact Audio Copy
  and XLD print it, the "skip zero" form, and its AccurateRip checksums, so
  that rips can be compared across programs.
- **Test and copy**, off by default: one more read of each track after its
  rip, with its CRC-32 beside the copy's in the report. Settings › Ripping,
  or `rip --test`.
- **The media type** in the report and in `silverside info`: a pressed CD, a
  CD-R, or a CD-RW.
- **More tags from MusicBrainz:** composers, lyricists, the genre, and sort
  names for the artist and the album artist.
- **The report records the encoding:** the format, the encoder and its
  settings, and each track's file. An "Encoded" chip and an Encoding column
  show it, for a new rip and an earlier one.
- An earlier rip shows its cover beside the result.
- A spinner while a rip or a MusicBrainz lookup is under way, and a status
  bar that says what the rip waits for.
- Help › Silverside Website. Acknowledgments names XLD and cyanrip as
  inspirations.

### Changed

- The website is [silverside.app](https://silverside.app). The About window
  opens it, and Silverside gives it to the services it asks.
- The bundle identifier is `app.silverside.Silverside`, the last of the
  rename from CDRip. macOS sees a new app: the welcome shows once more, and
  Fast mode and the window positions start afresh. Rips, settings, and drive
  profiles stay.

### Fixed

- The header said "not looked up" while MusicBrainz was being asked about a
  disc.
- The table of an earlier rip was too wide when the rip report was open.
- The rip report said "1 sectors".
- During a rip, the Rip Disc button stayed blue and dim. Stop takes its
  place, and the button is gray when there is nothing to rip.

## 0.4 (2026-10-22)

### Added

- **A welcome at the first launch.** It shows the CD drives that macOS has
  and asks what a rip should become: Apple Lossless, FLAC, AAC, MP3, or WAV
  files only. Help › Welcome to Silverside opens it again.
- **An About window**, with the version, how many discs you ripped and how
  many tracks are verified, the services Silverside uses, and
  Acknowledgments.
- **The MIT License.** The name "Silverside" and the icon and logo artwork are
  not covered by it. The app shows it from Acknowledgments, and
  `silverside license` prints it.
- **Silverside asks before it replaces files in your library.** When the
  library already has the album, a rip asks after it reads the disc: Replace,
  or Keep the Files, which keeps the rip for later. `silverside rip --encode`
  asks at a terminal, and `--overwrite` now works with `rip` as well as
  `encode`.
- **An Encoding column** in the track table, for each track's file while the
  album is encoded.
- **MP3 turns on by itself** when the LAME encoder is installed while the
  welcome or Settings is open. The environment variable `SILVERSIDE_LAME`
  names another `lame`, or with `none` acts as if there were none.
- **Help for common problems:** how to keep the Music app from opening when
  a CD goes in, why MP3 may not be a choice, and why a rip may not be
  encoded.
- **`docs/cli.md`**, the guide to the command-line tool.

### Changed

- Drives with a disc come first in the sidebar. A disc that goes in while
  the window shows an empty drive brings its drive into view.
- Without LAME, MP3 is left out of the formats in Settings › General (with a
  note), and its options in Settings › Encoding are dimmed.
- Settings › Encoding says what AAC is.
- The app's messages about encoding no longer name command-line options.
- Button titles use the ellipsis character (…).
- The help matches the app: the status names, what a rip folder holds, how
  pooling and repair work, and discs that MusicBrainz does not know.
- The README is for people who use the app, with a section on building from
  source; the command-line details moved to `docs/cli.md`.

### Fixed

- A second rip of a disc that was already in the library failed at the end,
  with "Use --overwrite" in the status bar.
- On macOS 15, the Rip button's disc turned white while it turned.
- The encoding progress counted a pre-emphasis warning as a track.

Checked on macOS 15.6.1 (a full rip, the drive test, and FLAC encoding) as
well as on the current macOS.
