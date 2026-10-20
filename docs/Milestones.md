# Milestones

The first goal is a usable CLI: rip a whole disc to tagged FLAC or ALAC files with correct names, and verify each track against AccurateRip. Milestones 1–5 reach that goal. Milestones 6–9 bring EAC-level robustness. The SwiftUI app comes after the CLI and uses the same engine.

| # | Milestone | Status |
|---|---|---|
| 1 | Engine basics | Done |
| 2 | Hardware access and CLI skeleton | Done |
| 3 | Rip to WAV with AccurateRip verification | In progress |
| 4 | Encoding and tags | Not started |
| 5 | Metadata | Not started |
| 6 | Secure re-reads | Not started |
| 7 | CTDB verification and repair | Not started |
| 8 | Rip log, CUE sheets, gaps and indexes | Not started |
| 9 | Multi-disc releases and style recipes | Not started |

## 1. Engine basics — done

- TOC model, including sessions, data tracks, and enhanced CDs.
- Disc IDs: MusicBrainz, AccurateRip, freedb, and the CTDB TOC string.
- AccurateRip v1 and v2 track checksums.
- `CDDrive` protocol and `SimulatedDrive`, which can simulate a read offset, overread, read errors, and silent corruption.
- `AudioReader`, which corrects the read offset.

## 2. Hardware access and CLI skeleton — done

Done:

- `IOKitDrive`: full TOC and audio reads through the `DKIOCCD*` ioctls on `/dev/rdiskN`.
- Hardware tests (`make hwtest`) that find the drive's offset from AccurateRip and check a ripped track.
- Offset detection: `AccurateRipOffsetFinder`, with the full-track v1 checksum and the sector 450 checksum (for v2-only records).
- Parser for AccurateRip database files.
- `cdrip` CLI skeleton with swift-argument-parser (`make cli ARGS='...'`).
- `cdrip info`: TOC, pregaps (binary search of the Q subchannel, with damaged frames skipped), silence check before track 1, disc IDs, ISRCs and MCN (from Q-subchannel frames), and AccurateRip and CTDB status (`--offline` skips the lookups). Uses the only drive with a CD unless `-d diskN` is given.
- `cdrip drives`: drives from the IOKit registry (vendor, product, firmware, connection) and their CDs.

Index points after index 01 are left for milestone 8: finding them needs the Q subchannel of every sector, which a rip reads anyway.

## 3. Rip to WAV with AccurateRip verification — in progress

Done:

- `cdrip rip [--tracks 1,3-5] [-o folder] [--offset n] [--offline]`: offset-corrected WAV files, and an AccurateRip result for each track (v1 and v2 submissions, or the other offsets that match).
- `TrackRipper` reads 5 sectors more on each side of a track, so it can find the other offsets that match without a second read. Each candidate is checked with the full-track checksum.
- `DriveOffsetList` reads AccurateRip's `DriveOffsets.bin` (69-byte records), with vendor aliases.
- Full-disc rips checked on hardware: Herbie Hancock, *Head Hunters* (4 of 4 tracks accurate, including the first and last), and Grateful Dead, *Reckoning* (10 of 15: the 5 others have C2 errors).
- `DriveProfile` and `DriveProfileStore`: `~/Library/Application Support/CDRip/DriveProfiles.json`. Offset order: manual, confirmed by rips of two or more discs, then AccurateRip's list. Rips in several drives can run at once: a save locks the file, reads it again, and changes only its own profile.
- Offsets confirmed by rips alone: +6 for the HL-DT-ST (*Head Hunters*, *Dick's Picks Vol. 2*) and for the ASUS (*Reckoning*, *Live/Dead*). Partly damaged discs count, because their good tracks still match.

To do:

- A way to set a drive's offset by hand (for example `cdrip drives --set-offset`), saved in its profile.
- Keep a copy of `DriveOffsets.bin`. Today it is downloaded once for each new drive.
- Offline rips: keep what is needed to check them against AccurateRip later.
- Speed: a 6½-minute track took 36 s on the HL-DT-ST (debug build). Profile the reads and the checksums.
- Memory: a track is held in memory as it is ripped (about 10 MB a minute). Long single-track discs need streaming.

### Offset handling

The drive's read offset aligns our samples with everyone else's, so AccurateRip and CTDB checksums can match. Verification itself does not need the drive's offset: a match at any offset proves an error-free read of the pressing that matches. But to make files that are bit-identical to other correct rips of the user's own pressing, we need the drive's offset. One disc cannot show it, because pressings are shifted against each other too.

1. **New drive:** look up the model in AccurateRip's drive offset list. Download `DriveOffsets.bin` (about 340 KB, 4,878 drive entries, 103 distinct offsets) when needed, keep a copy, and do not bundle it. Use the vendor aliases. Mark the offset "from AccurateRip's list".
2. **Every rip of a disc in AccurateRip:** keep the matching offsets in the drive's profile. When two or more discs leave one offset in common, the offset is confirmed. Warn if it disagrees with the list.
3. **Drive not in the list:** rip with the best guess. Verification still works. The rip log says the offset is not yet confirmed.
4. **Manual setting**, for users who know their drive's offset.
5. **Offline rips:** keep what is needed to verify them later, and verify when the network is available.

The rip log records the offset and its source. The drive profiles and past results are a separate store, which the app keeps.

## 4. Encoding and tags

- FLAC and ALAC through AudioToolbox. AIFF and WAV.
- After encoding, decode the file and compare it with the ripped PCM.
- Our own writers for FLAC metadata blocks (Vorbis comments, PICTURE) and MP4 `ilst` atoms.
- Optional external encoder hook (stdin to a command-line tool), for other formats.

## 5. Metadata

- MusicBrainz lookup by disc ID, then fuzzy TOC lookup.
- Choose among releases with the MCN (barcode) when the disc has one.
- File and folder name templates.
- Cover art from the Cover Art Archive.

After milestone 5, the CLI can rip clean discs for daily use.

## 6. Secure re-reads

- Re-read only the tracks that do not match AccurateRip.
- Defeat the drive's cache, compare multiple passes, and use C2 flags as a hint only.

## 7. CTDB verification and repair

- Verify against CUETools DB. Use parity repair as a last resort.

## 8. Rip log, CUE sheets, gaps and indexes

- A detailed rip log in our own format.
- Accurate CUE sheets, per-track output or image plus CUE.
- Pregaps, index points, hidden track one audio, pre-emphasis, ISRC, and CD-Text.

## 9. Multi-disc releases and style recipes

- A multi-disc release is one unit of work, so metadata stays consistent across discs and sessions.
- Apple Foundation Models for verification and cleanup of metadata from conventional sources only, with a non-AI path.
- Reusable style recipes, such as segue `>` marks and `[Venue, date]` suffixes.

## Hardware for testing

| Drive | Connection | Read offset | Notes |
|---|---|---|---|
| MATSHITA BD-MLT UJ260AF | USB, no hub | +103 | The only offset that matches on all 3 test discs; agrees with the AccurateRip list (648 submissions). No overread. C2, Q subchannel, CD-Text, and ISRC work. |
| ASUS BW-16D1HT, firmware 3.10, possibly LG inside and modified for LibreDrive | USB | +6 | Agrees with the AccurateRip list (3,015 submissions); matches on *Dozin' at the Knick* disc 1. About 24.7×, the fastest so far. |
| HL-DT-ST BD-RE BU50N (LG), firmware CC03, possibly modified for LibreDrive (MakeMKV) | USB, no hub | +6 | Agrees with the AccurateRip list (51 submissions); matches on *Clarity of Cal*, with the same checksums as the MATSHITA at +103. No overread. C2 and Q subchannel (with user area) work. Raw P-W subchannel gives `EIO`. Reports 20×. |

Drives report vendor names that differ from the names in AccurateRip's offset list. Drive profiles need a table of vendor aliases:

| Drive reports | AccurateRip lists |
|---|---|
| MATSHITA (Matsushita) | Panasonic, hp |
| HL-DT-ST (Hitachi-LG Data Storage) | LG Electronics, hp HLDS, hp |

Test discs:

- Grateful Dead, *Dozin' at the Knick*, disc 1, two copies with the same TOC: a used copy, and the original from 1996. In AccurateRip and CTDB, no CD-Text, HDCD logo on the disc. AccurateRip has five pressings. The original's audio is 195 samples later than the used copy's: it matches the second-largest group of submissions, and the used copy matches the largest.
- Vulfpeck, *Clarity of Cal* (2025, indie): CD-Text with vinyl side numbers in the track titles ("A1 Big Dipper"). One AccurateRip submission, v2 only. No MCN or ISRC in the Q subchannel. The barcode 3760420424738 is in MusicBrainz, but it was not found in about 1,200 sectors of Q subchannel.
- Beatles, *Past Masters Vol. 2* (1988 pressing): no ISRC, MCN, or pre-emphasis. In AccurateRip, but this pressing (at the drive's offset) has few submissions; two other pressings have many more.
- Miles Davis, *Kind of Blue* (1997 edition, 6 tracks): ISRCs (USSM159…), an MCN of all zeros (no barcode), pregaps of 1.7–4 seconds. AccurateRip 57 records; CTDB up to 5,905 submissions.
- Phish, *The Story of the Ghost* (1998 original): 32 silent sectors before track 1, an MCN (0075596229722), ISRCs on every track, and an MCN frame at the change from track 1 to track 2. The HL-DT-ST's ISRC command gave wrong codes for several tracks; the Q-subchannel frames are correct.
- Grateful Dead, *Summer Magic 1985* (20 discs): MusicBrainz disc IDs known. Not in AccurateRip when last checked.
- Pink Floyd, *The Endless River* (2014, major label): ISRCs on the disc (GBN9X1400051…), the same as in MusicBrainz. No MCN. CD-Text. Many pressings in AccurateRip, and one (+773) has more submissions than the drive's offset.
- To try: a Windows 98 CD (data track only).
- Herbie Hancock, *Head Hunters* (about 1999): long pregaps (1.9–2.3 s). All 4 tracks accurate on the HL-DT-ST at +6; the disc also matches at −1070 and −943.
- Grateful Dead, *Reckoning* (about 1993): **damaged**, the test disc for secure re-reads. On the ASUS, tracks 8, 11, 13, 14, and 15 are not accurate, and each has C2 errors (track 8: one spot every revolution, about 16 sectors; track 15: 179 sectors). The Q frames just before tracks 9 and 14 have bad CRCs, next to C2 errors in the audio (16 sectors, one revolution, before the frame at 262379). Track 12 was accurate in the rip, but a later C2 scan found 3 bad sectors: results on damaged areas change between reads, so C2 is a hint only. 33 silent sectors before track 1.
- Grateful Dead, *Reckoning*, on the MATSHITA too: the same 5 tracks fail, and the same Q frames have bad CRCs, so the faults are on the disc. Compared sample by sample, the two drives' rips differ in only 0.0004–0.03% of samples, in 4–192 sectors per track. Where they differ, the median difference is 32–44 (of 65,536 steps), and the largest about 4,000, which can be an audible click. Raw P-W subchannel from the MATSHITA was unusable on this disc: the same bytes at sectors far apart.
- Grateful Dead, *Dick's Picks Vol. 2*: **damaged**. 2 of 6 tracks accurate on the HL-DT-ST; track 2 has C2 errors in 39 sectors. No pregaps.
- Grateful Dead, *Live/Dead*: **damaged**. Only track 7 (35 s) accurate on the ASUS; tracks 2 and 6 have C2 errors. MCN 0075990183026. 32 silent sectors before track 1. Seven pressings in AccurateRip.
- Still to find: an enhanced CD, a disc with hidden track one audio, a pre-emphasis disc, and a scratched disc.
