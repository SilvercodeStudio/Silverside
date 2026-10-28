# Verification

A rip is only as good as the check that proves it. Silverside uses two databases, and both are independent of the drive.

## AccurateRip

AccurateRip holds checksums of each track from many people's rips of the same disc. A track that matches is **accurate**: the data is bit for bit what other drives read. The number after it (conf 52) is how many rips agree. A track can also match **another pressing**: the same audio at a different alignment, which also proves it free of errors. A CD-R copy of a disc usually matches this way, because the copy's audio is shifted by a few samples.

A disc that is not in AccurateRip cannot be proved this way. Then Silverside reads each track twice and reports whether the reads agree.

AccurateRip keeps no checksum for a track that is all silence, so such a track shows **No checksum**, not "Not accurate", even when the rest of the disc is in AccurateRip. CTDB checks it with the rest of the disc.

## CUETools database (CTDB)

CTDB checks the whole disc at once, so a rip of some tracks only is not checked. It also holds repair data: when a few thousand samples are wrong, CTDB can correct them. Silverside tries a repair when a track is not verified, then checks the repaired track against AccurateRip again. **Verified** means the disc matches an entry; **repaired** means it matches after the repair.

## Read offsets

Every drive reads a few samples early or late, by a fixed amount. Silverside corrects it, so rips from different drives come out the same, and AccurateRip checksums match. The offset comes from AccurateRip's list of drives, or from rips that confirm it. It is shown in Settings › Drives, where you can also set it by hand.

## Checksums

The report lists each track's CRC-32, as Exact Audio Copy and XLD print it, with EAC's "skip zero" form (silent samples left out) and the track's own AccurateRip checksums, so a rip can be compared with one from another program or another drive. With **test and copy** on in Settings › Ripping, each track is read once more after its rip, and the report says whether that read gave the same audio; a difference means the drive did not read the track the same way twice. The report also says whether the disc is a pressed CD, a CD-R, or a CD-RW: a CD-R of a show or a mix is in neither database, so nothing can verify it, and the reads alone decide.

## What the statuses mean

| Status | Meaning |
|---|---|
| Verified, green | AccurateRip or CTDB verifies the track. |
| Repaired, orange | CTDB's repair data corrected the track, and the result is verified. |
| Copied, grey | The reads agree, but no database has this disc to check against. |
| Not verified, red | No database matches the track, and a repair was not possible. |

Under a track's status, a short line says what the track needed: the sectors that were read again (in red when some never agreed), and the samples that CTDB corrected. The AccurateRip and CTDB columns show how many rips in each database have the track's checksum. Control-click the column headings to show more columns or hide some: the Re-reads column counts the re-read sectors in a column of their own.

## When tracks stay unverified

The result banner says what is most likely to help next. In short:

- Clean the disc and rip again. The new rip pools with the first (see Options under Ripping a Disc): a track that either rip got accurate is kept.
- Rip in another drive. Each drive reads damage differently, so two drives together often get what one cannot.
- Repair the rip.
- For a new release, wait, then use Check Again (below).
- Accept the rip as it is. When nothing verifies a few tracks, listen to them: damage that no drive can read is often a short spot you cannot hear. **Encode…** on the earlier rip asks you to accept it, then encodes it into the library as a verified rip is, and the rip's WAV files go unless Settings keep them. The report says that you accepted it and which tracks are not verified, and the rip shows an "Accepted as it is" chip. Check Again can still verify it later.

## Repair

Repair, in the toolbar of an earlier rip and in the Disc menu, checks the rip against CTDB again and repairs it with CTDB's data, as `silverside repair` does. Every other rip of the same disc in the rips folder joins the pool. When the disc is in a drive that is free, the sectors where the repair still fails are read again, which gives it more versions to try. To work on a few bad tracks, put the disc in a free drive (another drive often reads them better) and use Repair, not a rip of those tracks: a rip of some tracks writes into the earlier rip's folder with a report of those tracks only, and CTDB cannot check it.

A rip that CTDB verifies as it is gets its report brought up to date: a rip made offline becomes a verified rip. A rip that the repair changes stays as it was, and the repaired rip goes in a folder of its own next to it ("… repaired"), with its own report, so it can be encoded like any rip.

## Check Again

A new release is often in neither AccurateRip nor CTDB at first, so its tracks show as Copied: the reads agree, but no database can confirm them. Other people's rips fill the databases in over the weeks after a release, and CTDB usually has a disc first.

Check Again, in the toolbar of an earlier rip, looks the disc up in both databases again and checks the rip against what they have now. A set's toolbar has it too, for every disc that can use it. The disc does not have to be in a drive: Silverside checks the rip's WAV files, or, after they are deleted, the album's FLAC or Apple Lossless files, which must still decode to exactly the audio that was ripped. The rip's report gets the new results and the date of the check. A match found before is never lost, even if a database cannot be reached.

Check Again shows for a rip that is not verified, for one that AccurateRip or CTDB did not have, and for one with tracks AccurateRip did not match, since a second database is a second, independent proof. It cannot check AAC or MP3 files, or a library decoded from HDCD, as these are no longer the ripped audio. When CTDB has the disc now but the rip does not match, Repair can try to fix it. `silverside check` does the same from a terminal.

## Multi-disc sets

A set is done when every disc is verified and in the library. The chips on a disc say how far the set is ("Disc 2 of 3", and how many discs are ripped), and the set's view, under Sets in the sidebar, names each disc that still needs attention: one still to rip, one ripped but not verified, one verified but not encoded. See Sets under Ripping a Disc.
