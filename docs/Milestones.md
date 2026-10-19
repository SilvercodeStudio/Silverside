# Milestones

The first goal is a usable CLI: rip a whole disc to tagged FLAC or ALAC files with correct names, and verify each track against AccurateRip. Milestones 1–5 reach that goal. Milestones 6–9 bring EAC-level robustness. The SwiftUI app comes after the CLI and uses the same engine.

| # | Milestone | Status |
|---|---|---|
| 1 | Engine basics | Done |
| 2 | Hardware access and CLI skeleton | In progress |
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

## 2. Hardware access and CLI skeleton — in progress

Done:

- `IOKitDrive`: full TOC and audio reads through the `DKIOCCD*` ioctls on `/dev/rdiskN`.
- Hardware tests (`make hwtest`) that find the drive's offset from AccurateRip and check a ripped track.
- Offset detection: `AccurateRipOffsetFinder`.
- Parser for AccurateRip database files.
- `cdrip` CLI skeleton with swift-argument-parser (`make cli ARGS='...'`).
- `cdrip info -d diskN`: TOC and disc IDs.

To do:

- `cdrip drives`: find drives and discs through IOKit or DiskArbitration, and show vendor, product, and firmware.
- `cdrip info`: add AccurateRip status, plus MCN, ISRC, and pregaps from Q subchannel. Find the disc without `-d` when only one is inserted.

## 3. Rip to WAV with AccurateRip verification

- `cdrip rip`: rip every track (or chosen tracks) to WAV with offset correction.
- Report an AccurateRip result for each track: v1 or v2, and confidence.
- The first and last tracks on drives without overread: AccurateRip skips the samples that are lost.
- Drive profiles: where to store the offset and other capabilities for each drive and enclosure.

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
| MATSHITA BD-MLT UJ260AF | USB, no hub | +103 | Agrees with the AccurateRip list (648 submissions). No overread. C2 and Q subchannel work. |
| ASUS BW-16D1HT | OWC enclosure | — | Not tested yet |
| LG (model to be confirmed) | — | — | Not tested yet |

Drives report vendor names that differ from the names in AccurateRip's offset list. For example, "MATSHITA" (Matsushita) is listed as "Panasonic". Drive profiles need a table of vendor aliases.

Test discs:

- Grateful Dead, *Dozin' at the Knick*, disc 1: in AccurateRip and CTDB, no CD-Text, HDCD logo on the disc. AccurateRip matches four other pressings besides the one at the drive offset.
- Grateful Dead, *Summer Magic 1985* (20 discs): MusicBrainz disc IDs known. Not in AccurateRip when last checked.
- Still to find: a disc from an unrelated release, an enhanced CD, a disc with hidden track one audio, a pre-emphasis disc, and a scratched disc.
