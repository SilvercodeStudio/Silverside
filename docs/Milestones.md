# Milestones

The first goal is a usable CLI: rip a whole disc to tagged FLAC or ALAC files with correct names, and verify each track against AccurateRip. Milestones 1–5 reach that goal. Milestones 6–9 bring EAC-level robustness. The SwiftUI app comes after the CLI and uses the same engine.

| # | Milestone | Status |
|---|---|---|
| 1 | Engine basics | Done |
| 2 | Hardware access and CLI skeleton | Done |
| 3 | Rip to WAV with AccurateRip verification | Engine mostly done |
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
- `cdrip info`: TOC, pregaps (binary search of the Q subchannel, with damaged frames skipped), disc IDs, ISRCs, MCN, and AccurateRip and CTDB status (`--offline` skips the lookups). Uses the only drive with a CD unless `-d diskN` is given.
- `cdrip drives`: drives from the IOKit registry (vendor, product, firmware, connection) and their CDs.

Index points after index 01 are left for milestone 8: finding them needs the Q subchannel of every sector, which a rip reads anyway.

## 3. Rip to WAV with AccurateRip verification

- `cdrip rip`: rip every track (or chosen tracks) to WAV with offset correction.
- Report an AccurateRip result for each track: v1 or v2, and confidence.
- The first and last tracks on drives without overread: AccurateRip skips the samples that are lost.
- Drive profiles: where to store the offset and other capabilities for each drive and enclosure. Key them on firmware revision too, because modified firmware (such as LibreDrive) can change behavior. Find the offset from the AccurateRip drive offset list (with vendor aliases), or from the offsets that several discs share. One disc is not enough.

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
| ASUS BW-16D1HT | OWC enclosure | — | Not tested yet |
| HL-DT-ST BD-RE BU50N (LG), firmware CC03, possibly modified for LibreDrive (MakeMKV) | USB, no hub | +6 | Agrees with the AccurateRip list (51 submissions); matches on *Clarity of Cal*, with the same checksums as the MATSHITA at +103. No overread. C2 and Q subchannel (with user area) work. Raw P-W subchannel gives `EIO`. Reports 20×. |

Drives report vendor names that differ from the names in AccurateRip's offset list. Drive profiles need a table of vendor aliases:

| Drive reports | AccurateRip lists |
|---|---|
| MATSHITA (Matsushita) | Panasonic, hp |
| HL-DT-ST (Hitachi-LG Data Storage) | LG Electronics, hp HLDS, hp |

Test discs:

- Grateful Dead, *Dozin' at the Knick*, disc 1: in AccurateRip and CTDB, no CD-Text, HDCD logo on the disc. AccurateRip matches four other pressings besides the one at the drive offset.
- Vulfpeck, *Clarity of Cal* (2025, indie): CD-Text with vinyl side numbers in the track titles ("A1 Big Dipper"). One AccurateRip submission, v2 only. No MCN or ISRC in the Q subchannel. The barcode 3760420424738 is in MusicBrainz, but it was not found in about 1,200 sectors of Q subchannel.
- Beatles, *Past Masters Vol. 2* (1988 pressing): no ISRC, MCN, or pre-emphasis. In AccurateRip, but this pressing (at the drive's offset) has few submissions; two other pressings have many more.
- Miles Davis, *Kind of Blue* (1997 edition, 6 tracks): ISRCs (USSM159…), an MCN of all zeros (no barcode), pregaps of 1.7–4 seconds. AccurateRip 57 records; CTDB up to 5,905 submissions.
- Grateful Dead, *Summer Magic 1985* (20 discs): MusicBrainz disc IDs known. Not in AccurateRip when last checked.
- Pink Floyd, *The Endless River* (2014, major label): ISRCs on the disc (GBN9X1400051…), the same as in MusicBrainz. No MCN. CD-Text. Many pressings in AccurateRip, and one (+773) has more submissions than the drive's offset.
- Still to find: a disc with an MCN, an enhanced CD, a disc with hidden track one audio, a pre-emphasis disc, and a scratched disc.
