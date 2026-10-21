# Milestones

The first goal is a usable CLI: rip a whole disc to tagged FLAC or ALAC files with correct names, and verify each track against AccurateRip. Milestones 1–5 reach that goal. Milestones 6–9 bring EAC-level robustness. The SwiftUI app comes after the CLI and uses the same engine.

| # | Milestone | Status |
|---|---|---|
| 1 | Engine basics | Done |
| 2 | Hardware access and CLI skeleton | Done |
| 3 | Rip to WAV with AccurateRip verification | Done |
| 4 | Encoding and tags | Mostly done |
| 5 | Metadata | Mostly done |
| 6 | Secure re-reads | Done |
| 7 | CTDB verification and repair | Done |
| 8 | Rip log, CUE sheets, gaps and indexes | Mostly done |
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

## 3. Rip to WAV with AccurateRip verification — done

Done:

- `cdrip rip [--tracks 1,3-5] [-o folder] [--offset n] [--offline]`: offset-corrected WAV files, and an AccurateRip result for each track (v1 and v2 submissions, or the other offsets that match).
- `TrackRipper` reads 5 sectors more on each side of a track, so it can find the other offsets that match without a second read. Each candidate is checked with the full-track checksum.
- `DriveOffsetList` reads AccurateRip's `DriveOffsets.bin` (69-byte records), with vendor aliases.
- Full-disc rips checked on hardware: Herbie Hancock, *Head Hunters* (4 of 4 tracks accurate, including the first and last), and Grateful Dead, *Reckoning* (10 of 15: the 5 others have C2 errors).
- `DriveProfile` and `DriveProfileStore`: `~/Library/Application Support/CDRip/DriveProfiles.json`. Offset order: manual, confirmed by rips of two or more discs, then AccurateRip's list. Rips in several drives can run at once: a save locks the file, reads it again, and changes only its own profile.
- Offsets confirmed by rips alone: +6 for the HL-DT-ST (*Head Hunters*, *Dick's Picks Vol. 2*, *Europe '72* disc 2) and for the ASUS (*Reckoning*, *Live/Dead*, *Lost in the Wonder*). Three rips in three drives ran at once with no lost profile updates. +103 for the MATSHITA (*Europe '72* disc 1, *Live at Leeds*), so all three drives are confirmed by rips, and each agrees with AccurateRip's list. Partly damaged discs count, because their good tracks still match.

- Speed: the drive is the limit, not the code. A 5½-minute track rips in 26 s on the HL-DT-ST (release build) with 0.2 s of CPU time, and a 57-minute disc in about 4½ minutes (about 13×). Reading C2 flags with the audio costs no time.

- `cdrip drives --set-offset N -d diskN` sets a drive's offset by hand, saved in its profile; `--clear-offset` removes it. `cdrip drives` shows each drive's offset and its source.
- `DriveOffsets.bin` is kept in the `WebClient` cache, and a profile keeps the offset once it is found. When a request fails, the cache gives its copy, however old.
- Offline rips: `cdrip rip --offline` writes `disc.json` with the WAV files. Later, `cdrip repair -i <folder>` reads the TOC from it, and checks the rip against AccurateRip and CTDB with no disc.
- Memory: a rip holds the whole disc for CTDB (about 640 MB for 60 minutes). That is acceptable, so long single-track discs need no streaming.

### Offset handling

The drive's read offset aligns our samples with everyone else's, so AccurateRip and CTDB checksums can match. Verification itself does not need the drive's offset: a match at any offset proves an error-free read of the pressing that matches. But to make files that are bit-identical to other correct rips of the user's own pressing, we need the drive's offset. One disc cannot show it, because pressings are shifted against each other too.

1. **New drive:** look up the model in AccurateRip's drive offset list. Download `DriveOffsets.bin` (about 340 KB, 4,878 drive entries, 103 distinct offsets) when needed, keep a copy, and do not bundle it. Use the vendor aliases. Mark the offset "from AccurateRip's list".
2. **Every rip of a disc in AccurateRip:** keep the matching offsets in the drive's profile. When two or more discs leave one offset in common, the offset is confirmed. Warn if it disagrees with the list.
3. **Drive not in the list:** rip with the best guess. Verification still works. The rip log says the offset is not yet confirmed.
4. **Manual setting**, for users who know their drive's offset.
5. **Offline rips:** keep what is needed to verify them later, and verify when the network is available.

The rip log records the offset and its source. The drive profiles and past results are a separate store, which the app keeps.

## 4. Encoding and tags — mostly done

Done:

- `AudioEncoder`: FLAC, ALAC, AAC (256 kbit/s by default), and AIFF through AudioToolbox (`ExtAudioFile`), and decoding of any of them. FLAC, ALAC, and AIFF give back every sample. Apple's FLAC files have a correct audio MD5 (`flac -t` passes). WAV uses `WAVFile`.
- MP3 through `lame` (`MP3Encoder`, `-V 0`, about 245 kbit/s): CDRip pipes the PCM to it, and writes the ID3v2.4 tag itself (`ID3Tags`). Running LAME as a separate program keeps its LGPL code out of CDRip. Apple's frameworks have no MP3 encoder (`afconvert` fails with `'fmt?'`).
- `FLACTags`: our own metadata blocks. Apple writes STREAMINFO and a small VORBIS_COMMENT; CDRip keeps STREAMINFO and any other blocks, writes its VORBIS_COMMENT (vendor "CDRip <version>", now 0.2) and a PICTURE block (type 3, front cover), adds 8 KB of padding, and copies the audio frames unchanged.
- `MP4Tags`: `moov/udta/meta/ilst` with iTunes atoms (`©nam`, `©ART`, `aART`, `©alb`, `©day`, `trkn`, `disk`, `covr`, `©too`), and freeform `----` atoms named as MusicBrainz Picard names them (ISRC, BARCODE, the MusicBrainz IDs, and so on). Apple puts `moov` before `mdat`, so new tags move the audio: the writer drops the `free` atom and moves every `stco`/`co64` chunk offset by the same amount. The encoder's own items (such as `iTunSMPB`, for gapless AAC) are kept.
- `ID3Tags`: text frames, `TXXX` and `UFID` for the MusicBrainz IDs as Picard writes them, and `APIC` for the cover; any ID3 tags that `lame` wrote are replaced.
- `EmbeddedCover`: the embedded cover is at most 1000 px on its long side (ImageIO), as in the user's library; a cover within the size is kept byte for byte. The album folder keeps the full-size `cover.jpg`.
- `RippedDisc` reads a rip's folder in either form (a rip's `disc.json`, or an archive manifest). A track is verified if it is accurate in AccurateRip, matches another pressing, or matches a CTDB entry (or, for older manifests, if the disc is marked complete).
- `DiscEncoder` encodes each track to a partial file, tags it, decodes it again (a lossless file must equal the rip; a lossy one must be about as long), and only then moves it into place. It refuses unverified tracks (`--allow-unverified`) and files that exist (`--overwrite`).
- `cdrip encode -i <folder> [-i <folder> ...] [--format flac] [-l <library>]`, with `--folder-template`, `--track-template`, `--no-live-show-style`, and `--aac-bitrate`. The default library is `~/Music/CDRip Library`. `cdrip rip --encode flac` encodes the disc after the rip.
- Checked with outside tools on *Cornell 5/8/77*: `flac -t` passes on all 20 FLAC files, `metaflac` shows the blocks in order, and `ffprobe` reads the tags and the 1000 × 1000 cover in FLAC, ALAC, AAC, and MP3. 20 FLAC tracks (2 hours 10 minutes) encode and check in 38 s.

Still to do:

- Tags for AIFF (an `ID3 ` chunk) and WAV (a `LIST`/`INFO` chunk, or an `id3 ` chunk). Today they have none.
- Optional external encoder hook (stdin to a command-line tool), for other formats.
- Names and tags by hand, for a disc that MusicBrainz does not know at all (no disc ID and no fuzzy match): today such a rip cannot be encoded. For example, a template `disc.json` release to fill in, or options for the artist, album, and titles.

## 5. Metadata

The MusicBrainz client must protect the user's access to MusicBrainz. Done: `WebClient` does this for every web service.

- A rate limit for each host (MusicBrainz 1 request every 2 seconds, the Cover Art Archive 1 per second, AccurateRip and CTDB 5 per second). MusicBrainz's limit is 1 per second, but it answered 503 to requests 1.5 s apart, perhaps at a busy time of day. The time of the last request is in `~/Library/Caches/CDRip/rate/<host>`, under a lock, so the limit holds across `cdrip` processes.
- On 503 or 429, wait (honor `Retry-After`, else a delay that doubles from 2 s), and give up after 4 tries.
- A cache on disk (`~/Library/Caches/CDRip/web/`) keyed by URL. Responses stay 7 days for MusicBrainz, 30 for cover art, 1 for AccurateRip and CTDB lookups, and 365 for CTDB repair data. A 404 stays 1 day.
- Tests use a fake transport, so `make test` never touches the network.
- User-Agent: `CDRip/<version> ( https://preston-landers.github.io/CDRip )`. Never an email address.

Done:

- `MusicBrainzClient`: one request per disc, `discid/<id>?toc=...`. MusicBrainz returns the releases with the disc ID, or, if it does not know the ID, the releases whose TOC is nearly the same (a fuzzy match). The answer has an `id` only for an exact match. Each release has its artist credit, date, country, status, barcode, labels and catalog numbers, release group, every medium with its disc IDs and tracks (title, length, credit, recording ID), and whether the Cover Art Archive has a front cover. `MusicBrainzRelease` is Codable in CDRip's own form, so `disc.json` keeps it.
- `ReleaseRanking`: one disc ID can belong to several releases (*Madison Square Garden 3/9/81* and the 17-disc box set *In and Out of the Garden*; *Cornell 5/8/77* and the 11-disc *May 1977: Get Shown the Light*). The order: a release the user chose for any disc of the set, a barcode that matches the MCN (a 12-digit UPC is the EAN with a leading zero), an exact match, an official release, fewer media, then MusicBrainz's order.
- `ReleaseChoiceStore` (`~/Library/Application Support/CDRip/ReleaseChoices.json`): a release chosen with `--release` is kept for every disc ID of its media, so the other discs of the set get it too.
- `CoverArtClient`: the Cover Art Archive's list of images for a release. The front cover is saved as `cover.jpg` or `cover.png` (from the image's first bytes). With `--artwork all` (on `rip` and `metadata`), the other images go in `Artwork/`, named by type: `back.jpg`, `booklet-01.jpg`, `medium.jpg`. `--artwork none` saves nothing. `cdrip metadata --cover <file>` uses the user's image instead.
- `NameTemplate`: fields in braces (`{disc:2}` pads to two digits), parts in brackets that are kept only when all their fields have values, `/` for subfolders. The default folder name is the archive's: `{artist} - {album}[ (Disc {disc})]`. The user's library style is `libraryFolder` (`{albumArtist}/{album}`, all discs in one folder) and `libraryTrack` (`[{disc:2}-]{track} {title}`: "18-03 Walkin' Blues"). Values are made safe for file names (`/` and `:` become `-`, no control characters, no leading dots, at most 240 bytes).
- `cdrip metadata [-d diskN | -i folder] [--release ID] [--cover file]`: shows the ranked releases and the tracks. With `-i`, it writes the release into the folder's `disc.json` (keeping every other key) and saves the cover.
- `TrackMetadata`: one place for each track's title, Vorbis comments, and name fields, so names and tags agree. The tags follow the user's library (`TITLE`, `ARTIST`, `ALBUMARTIST`, `ALBUM`, `DISCNUMBER`, `DISCTOTAL`, `TRACKNUMBER`, `TRACKTOTAL`, `DISCSUBTITLE`, `DATE`, `ORIGINALDATE`), then `ISRC`, `BARCODE`, `LABEL`, `CATALOGNUMBER`, `RELEASECOUNTRY`, and the MusicBrainz IDs as Picard names them.
- **The live-show style**, on by default: when every disc of a release has a title such as "1985-07-01 Merriweather Post Pavilion, Columbia, MD", the disc's `DISCSUBTITLE` is that title, its `DATE` is the show's date (the release's date becomes `ORIGINALDATE`), and each title ends with "[Merriweather Post Pavilion, 7-1-85]", in the tags and in the file names. Tested against the user's *Summer Magic 1985* files.
- **Ambiguous releases:** `ReleaseRanking.isAmbiguous` is true when the first two releases are a real choice: not when the user chose the first before, not when only the first matches the MCN, and not when both are editions of the same release (same title and number of discs). Then `cdrip rip`, run at a terminal, asks which release to use (the first is the default) and remembers the answer for the other discs of the set. A rip in the background uses the first.
- `cdrip rip` looks up the disc (unless `--offline`), names the folder from the release, keeps the release, the MCN, and each track's ISRC in `disc.json`, and saves the front cover. A failed lookup does not stop the rip.
- Tests use saved answers (`Tests/CDRipKitTests/Resources/MusicBrainz`), so `make test` never touches the network.

Still to do:

- Embedded cover art (milestone 4): a FLAC PICTURE block (type 3, front cover), or the MP4 `covr` atom for ALAC and AAC, with one size limit (for example, 1000 px on the long side) so files stay small; the folder copy keeps full size.
- The live-show style for single shows (milestone 9). MusicBrainz gives no disc titles for any single-show release in the archive, so the venue and date must come from elsewhere: the release title ("Dave's Picks Vol. 59: Boston Garden, Boston, MA 9/26/91"), or the recordings' "recorded at" relationships (a place and a date; the city and state need the place's area). Not every title has a venue ("Cornell 5/8/77" was at Barton Hall).
- Genres (the user's files have `GENRE=Rock`): MusicBrainz has them with `inc=genres`, from votes; choose how to map them.

Done on the archive: all 31 folders have the full release in `disc.json` (31 requests; one 503 that a retry 30 s later fixed), and the 25 covers that the Cover Art Archive has. The user's library, for reference: `/Volumes/storage/planders/media/Music/Grateful Dead` (*Summer Magic 1985*: 20 discs in one folder, Vorbis comments `TITLE`, `ARTIST`, `ALBUMARTIST`, `ALBUM`, `DISCNUMBER`, `DISCTOTAL`, `TRACKNUMBER`, `TRACKTOTAL`, `DISCSUBTITLE`, `DATE`, `ORIGINALDATE`, `GENRE`, and a 1000 × 1000 JPEG front cover embedded).

After milestone 5, the CLI can rip clean discs for daily use.

## 6. Secure re-reads — done

Findings that shaped the design (MATSHITA, *Europe '72* disc 1, a damaged sector in track 9):

- **The cache hides re-reads.** Six back-to-back reads of the sector returned the same data, five of them in 0.5 ms from the cache. After a read of 3,000 sectors elsewhere, each read took about 233 ms and came from the disc.
- **Real re-reads of a damaged sector can alternate between two versions** (here on every read), so a majority vote cannot choose. AccurateRip can: its v1 and v2 checksums are sums of one term for each sample, so each version of a sector changes the track's checksum by a fixed amount, and combinations can be tested without reading the track again.
- **Two reads can be wrong in the same way**, so a sector is not proved good because two reads agree.
- **Errors that appear on one read only** are common: a second rip of tracks 5 and 6 matched AccurateRip.

Done (`SecureRipper`, the default in `cdrip rip`; `--single-pass` turns it off):

1. Rip the track once. If it matches AccurateRip, at the drive's offset or another, stop.
2. Flush the cache (read up to 4,000 sectors far from the track, never inside it), and read the whole track again. Sectors that differ from the first read are suspect. A track that does not match AccurateRip gets up to 4 full reads while they show new suspect sectors.
3. Re-read only the suspect sectors, after a cache flush each round. Keep every version of each sector, with how often it came back.
4. After each round, use the most frequent version of each sector, and test it and the combinations of versions (up to 65,536) against AccurateRip.
5. Without AccurateRip, a sector is resolved when one version leads all others by 3 reads.
6. Stop after 16 rounds, or after 4 rounds that give no new version, with another full read first if one is still allowed.
   Combinations are tested in order of how many sectors they change (one, then two, ...), with each sector's 4 most frequent versions, up to 65,536 for each round.
7. Report: accurate, matches only other pressings (free of errors), reads agree (not in AccurateRip), reads agree but not accurate, or suspect with the unresolved sectors.

`SimulatedDrive` models the findings: sectors that alternate on each read from the disc (and keep their data across one continuous read), errors that stay the same, and a cache.

Results so far:

- Clean discs cost nothing extra: every track that matches AccurateRip is read once (*Civilization IV*, *Two from the Vault* disc 1).
- *The 1968 Demos* (damage on the label side near the outer edge): 10 tracks accurate, 13 free of errors (they match another pressing, at −688), and the 3 tracks at the end of the disc unresolved after 16 rounds (up to 132 suspect sectors).
- *Europe '72* disc 1 on the MATSHITA: tracks 1, 2, 8, 9, and 10 stay unresolved. Each round gives new versions of the suspect sectors (up to 5 in track 8), and no combination that changes up to about 4 sectors matches. The drive probably conceals unreadable data by interpolation, differently on each read, so the true data never comes back. (A plain second rip did fix tracks 5 and 6, whose errors appeared on one read only.)
- A track that does not recover takes 3–7 minutes (16 rounds, each after a cache flush).

- The same tracks on the ASUS do not recover either, and it reads this disc worse (42 suspect sectors in track 8, the MATSHITA 13). But the two drives' final results for track 8 differ in 74 sectors, more than both drives' suspect sectors together. So each drive reads some sectors wrong the same way every time: re-reads in one drive cannot find them, and a comparison between drives can.

Watch for in normal use:

- A shifted read on real hardware (seen once, on *One from the Vault* disc 2 on the ASUS, before the detection existed). The simulator tests the detection.
- A disc that needs other limits (rounds, combinations). The defaults have worked on every disc so far.

Done:

- **Shifted reads.** On *One from the Vault* disc 2 (ASUS), one read of track 3 made 57,059 of its 59,127 sectors suspect, and the secure rip took 21 minutes; a read of track 1 differed in 14.4 million samples. Now, when a run of 32 or more sectors differs from the first read, the ripper looks for one shift (up to 10 sectors either way) that explains both the start and the end of the run. Damage changes data in place, so no shift explains it. A shifted read is left out and read again. If two later reads agree with each other and not with the first read, the first read lost its place, and a later read replaces it. `SimulatedDrive.slips` models a drive that loses its place.
- **C2 flags.** `CDDrive.readAudioSectorsWithC2` (294 flag bytes for each sector, one bit for each byte). The first read of each track asks for them, and a drive that refuses gives a plain read (`cdrip rip --no-c2` turns them off). Sectors with C2 errors are re-read even if every read agrees, and their flagged samples are suspects for CTDB, exact to the sample. The simulator flags the bytes that it returns wrong.
- **Unreadable sectors.** One sector that gave `EIO` stopped a whole rip (*Dick's Picks Vol. 1* disc 2 on the ASUS, track 8). Now `AudioReader.unreadableRetries` reads a failed chunk again sector by sector; a sector that still fails is silence, and the rip goes on. Such sectors are re-read like C2 sectors, a failed re-read gives no version, and their samples are erasures for CTDB.
- **Cache size for each drive.** `CacheProbe` reads a sector, then N sectors elsewhere, then the sector again: a read from the cache takes about 0.5 ms, and one from the disc 30–240 ms. It doubles N, then bisects. `cdrip drives -d diskN --measure-cache` keeps the result in the drive's profile, and rips and repairs then flush twice that many sectors (at least 256), in place of 4,000. All three drives keep only the latest read: one sector read anywhere else, even 2,000 sectors ahead, empties the cache. So their flush is 256 sectors, which saves about 3½ s on each round of re-reads.
- **`cdrip rip --pool <folder>`** (more than once) adds earlier rips of the disc, from any drive. For a track that is not accurate, an accurate earlier version replaces it; otherwise all versions, and their saved suspects, join the CTDB repair. A folder whose `disc.json` has another TOC is refused.
- **Pooling across drives.** `cdrip repair` pools rips from several drives. Each rip keeps its suspect samples and their other values in `Track NN.suspects` files, so the pool has every drive's versions, not only the majority value of each file.
- The rip report (`disc.json`) lists each track's suspect, unresolved, and C2 sectors, and its shifted reads.

## 7. CTDB verification and repair — done

How CTDB works, from reading CUETools (for understanding only; our code is our own) and checked against real entries:

- The disc's audio, from the first audio track to the lead-out, is 16-bit words. Rows are 11,760 words (10 sectors). The first row, and the last row plus the remainder, are left out.
- The disc CRC is CRC-32 of the rest. On *Two from the Vault* disc 1, our rip matches the main entry (360 submissions) at a shift of +1195 samples: CTDB stores this disc at the alignment of another pressing.
- Each column is a Reed–Solomon codeword over GF(2¹⁶) (polynomial 0x1100B). The repair data is 8 or 16 syndromes for each of the 11,760 columns (up to 376 KB). Our column-0 syndromes equal the lookup's `syndrome` attribute.

Done:

- `CTDB`: layout, disc and track CRCs, syndromes (in parallel, with byte tables: two passes for a 55-minute disc in under half a second), the shift search, and repair with a CRC check afterwards.
- `ReedSolomonDecoder`: Berlekamp–Massey with erasures, Chien search, Forney. e erasures and v unknown errors are corrected while e + 2v ≤ the number of syndromes.
- `cdrip repair -i folder [-i folder ...] [-d diskN | --toc ...]`: verifies ripped WAV files against CTDB, or repairs them. With several folders (rips of the same disc), each track uses a version that matches AccurateRip if one exists; otherwise the majority value of each sample. Samples where the versions disagree are suspect: a column that cannot be decoded is decoded again with them as erasures, then with the other versions of its suspect words. With the disc in a drive, the suspect sectors of columns that still fail are re-read. Repaired tracks are checked against AccurateRip too.
- `DiscRepairer` (CDRipKit) holds the repair steps, so `cdrip rip`, `cdrip repair`, and the app share them. Each track comes in as `TrackAudio`: its samples, and the other values that reads gave for its suspect samples. These come from several rips (the majority value per sample) or from the secure ripper's sector versions. Without repair, it only checks CRCs, at shift 0 and at each shift where column 0 matches an entry exactly. It also gives, for each track, the most submissions of an entry whose track CRC matches.
- **Repair during `cdrip rip`.** A rip of the whole disc is checked against CTDB. If a track is not free of errors, the rip is repaired with the secure ripper's versions as suspects, and with re-reads of columns that fail. Repaired tracks are written again and checked against AccurateRip again. `--no-repair` only checks. A rip of some tracks only is not checked, because CTDB checks the whole disc. `rip` keeps the disc's audio in memory for this (about 640 MB for 60 minutes), which is acceptable.
- All clean full rips verify: *Two from the Vault* disc 1, *Head Hunters*, *Lost in the Wonder*, *Civilization IV*, and both *Strange Remain* discs.

**First full repair: *Reckoning*.** From the ASUS rip and the MATSHITA re-rip of its 5 failed tracks, `cdrip repair` corrected 8,345 samples with CTDB entry 2111910 (19 submissions) at shift 0, and all 15 tracks then matched AccurateRip, which is independent of CTDB. The largest entry (31 submissions) is stored at another pressing's alignment, and fails at every shift: trying more than one entry matters.

Findings on *Europe '72* disc 1 (5 damaged tracks, 5 rips pooled):

| Method | Columns with errors | Columns that cannot be corrected |
|---|---|---|
| First rip only | 9,034 | 90 |
| Pooled, whole disagreeing sectors as erasures | 9,375 | 231 |
| Pooled, disagreeing samples as erasures | 9,375 | 361 |
| Pooled, majority value, erasures only when needed | 6,672 | 5 |
| ... and other reads' versions of suspect words | 6,672 | 1 |

- Whole sectors as erasures are far too coarse: each column gets about 62, and only 16 fit. Erasures that are right also use up capacity, so decode without them first.
- With many erasures, a wrong combination can decode "successfully": with e erasures and no other errors, e syndromes explain any difference. After re-reads, every column decoded once, but the disc CRC then did not match. So erasure decoding now keeps 2 syndromes spare (2v + e ≤ npar − 2).
- When a repair cannot finish (some columns cannot be corrected, or the disc CRC fails), the corrections are still kept in each track whose CTDB track CRC then matches: those tracks are proved.
- Not every CTDB entry has repair data (no `hasparity`), and small entries often have 8 syndromes per column, not 16. Different entries can be different pressings, or the same pressing with a submitter's errors, so try every entry, not just the largest.
- Re-reads made by `repair` are kept as "<first folder> read 2", "read 3", and so on, and later runs load them.
- On a very damaged disc, column 0 itself can have too many errors to find the shift (*Live/Dead*). The offsets where tracks match AccurateRip are hints: a shift where any of an entry's track CRCs matches is right.

Results on the damaged discs so far:

| Disc | Before | After `cdrip repair` |
|---|---|---|
| *Reckoning* | 10 of 15 accurate | **15 of 15** (8,345 samples corrected) |
| *Europe '72* disc 1 | 5 of 10 | **10 of 10** (7,757 samples; one re-read on the MATSHITA) |
| *Dick's Picks Vol. 2* | 2 of 6 | 4 of 6 (tracks 4 and 5 proved by their CTDB track CRCs; 5 columns uncorrectable). Later **6 of 6**, with repair during `cdrip rip` on the MATSHITA (below) |
| *Europe '72* disc 2 | 2 of 7 | **7 of 7** (12,871 samples): needed reads from three drives (HL-DT-ST, ASUS, MATSHITA); with two drives, 67 columns stayed uncorrectable |
| *The 1968 Demos* | 10 accurate, 13 free of errors | beyond CTDB: the entries that match this pressing (at shift 0) have no repair data, and the two that do are other pressings' (−324, −694) with only 8 syndromes per column |
| *One from the Vault* disc 1 | 6 of 8 | **8 of 8** (3,203 samples) |
| *One from the Vault* disc 2 (a long scratch) | 4 of 8 | **8 of 8** (18,391 samples) |
| *Live/Dead* | 1 of 7 | beyond CTDB: three reads from two drives disagree in about 108,000 samples of track 4 (damage to the reflective layer), and most columns are uncorrectable |

Every "accurate" result after a repair is from AccurateRip, which is independent of CTDB.

Repair during `cdrip rip`, one rip in one drive, after light cleaning of the discs:

| Disc | Drive | Result |
|---|---|---|
| *Reckoning* | HL-DT-ST | **15 of 15** (5 tracks repaired, 5,993 samples). Before, this needed rips from two drives. |
| *Europe '72* disc 2 | MATSHITA | **7 of 7** (2 tracks repaired, 6,567 samples). Before, this needed reads from three drives. |
| *Dick's Picks Vol. 2* | ASUS | 4 of 6 (tracks 3–6 repaired, 1,089 samples); 2 columns (6746, 6838) uncorrectable. Pooled with the HL-DT-ST rip and re-read in the ASUS: the same 2 columns, and the re-reads gave no new versions. |
| *Dick's Picks Vol. 2* | MATSHITA | **6 of 6** (4 tracks repaired, 25,574 samples), from this one rip. The MATSHITA gave more versions of each damaged sector (up to 18, against 12 on the ASUS). |
| *Hundred Year Hall* disc (4 tracks) | ASUS | **4 of 4** (2 tracks repaired, 18,422 samples) |
| *Hundred Year Hall* disc 1 (11 tracks) | HL-DT-ST | 6 of 11. Tracks 10 and 11 have 482 and 171 suspect sectors; 2,465 columns uncorrectable with the main entry (564 submissions), too many to re-read (512 at most). |
| *Hundred Year Hall* disc 1 | MATSHITA | 6 of 11 alone (367 columns uncorrectable; 290 in a second rip with C2). Pooled with the HL-DT-ST rip: 18 columns. Three rips pooled: **9 of 11** (track 2 repaired and proved), 4 columns uncorrectable. |

Two things changed at once, so the cause is not known: the cleaning, and the suspects, which now come from the secure ripper's re-reads after cache flushes, not from whole extra rips.

To do:

Done:

- *Live/Dead* in a second drive (MATSHITA): track 6 is now accurate too (2 of 7), but the disc is beyond repair. Track 4 has 4,318 suspect sectors (about 60% of it, 35 minutes of re-reads), and with the ASUS rip pooled, the repair still fails in almost every column.

- Re-read versions are kept on disk (`Track NN.suspects`, by `rip` and by `repair`), so a failed run does not lose them. A later `repair` loads them.
- **Erasure subsets.** A column can have more suspect words than its syndromes can erase (14 of 16, with 2 kept to check). When at most 16 columns fail, the decoder tries up to 200,000 random subsets of a column's suspects as erasures. With the places known, the values are the solution of a linear system, so each try is fast, and the spare syndromes and the CRC catch a wrong result. On *Hundred Year Hall* disc 1 (three rips pooled), it did not solve the last 4 columns: they have 18 to 30 suspects each, too many wrong words for a subset of 14 to hold them all.
- The log names each failing column, when 8 or fewer fail, with its number of suspect words.
- Tracks that match another pressing are found for the first and last tracks too: the audio past the disc's edges is silence, which AccurateRip skips.

## 8. Rip log, CUE sheets, gaps and indexes — mostly done

Done:

- The rip report: `disc.json` (`RipReport`, for programs) and `Rip Report.md` (for people: the result, a table of tracks with titles, lengths, pregaps, AccurateRip and CTDB results, reads, suspect, C2, and unreadable sectors, repairs, and ISRCs, then problems, the disc's IDs and CD-Text, and the drive). `rip` writes both in the rip's folder; encoding puts both in the album folder, as `Rip Report (Disc N).json` and `.md`.
- `rip` records each track's pregap (`PregapFinder`, a binary search of the Q subchannel), ISRC, and the MCN.
- `CueSheet`: one file for each track, each pregap at the end of the file before it (the "noncompliant" layout, which rebuilds the disc exactly), with `CATALOG` (the MCN), titles, performers, ISRCs, `FLAGS DCP`/`PRE`, and `REM` lines (date, freedb ID, disc number). Track 1's gap of silence is a `PREGAP`. Encoding writes `<album> (Disc N).cue` in the album folder, with the tags' titles and file names.
- CD-Text (`CDText`, `CDDrive.readCDText`): the TOC ioctl in its CD-Text format, 18-byte packs checked by their CRC-16, block 0 in ISO 8859-1, TAB for "the same as the track before". `info` shows it, and the rip report keeps it. Checked on *Clarity of Cal* (HL-DT-ST): the album, the performer, and all 11 titles ("A1 Big Dipper" ... "B6 This Is Not The Song I Wrote").
- Hidden track one audio (`HiddenTrackRip`): the part of the disc before track 1 is read; if its peak is 32 or more (out of 32,767), it is audio, ripped as `Track 00.wav` until two reads agree (AccurateRip and CTDB do not cover it), and encoded as track 0 ("01-00 Hidden Track", or MusicBrainz's pregap track's title). The CUE sheet puts track 1's `INDEX 00` in its file. A gap of silence (32 or 33 sectors on six archived discs) stays a `PREGAP`. Tested with the simulator; no disc with a hidden track has been ripped yet.
- Tags for AIFF (an `ID3 ` chunk) and WAV (an `id3 ` chunk, and a `LIST`/`INFO` chunk), with the audio unchanged.
- Compilations: the library's track name is `[{disc:2}-]{track} [{otherArtist} - ]{title}`, where `otherArtist` is the track's artist only when it is not the album's ("02 Mark Cromer & Jeff Briggs - Asoka").
- Pre-emphasis: the rip report and the CUE sheet (`FLAGS PRE`) mark it, and encoding warns. No common tag in FLAC, MP4, or ID3 marks it, and CDRip does not change the audio: de-emphasis would change samples that AccurateRip verified.

Still to do:

- A disc with a real hidden track, on hardware.
- CD-Text as names for a disc that MusicBrainz does not know (see milestone 4), and CD-Text in other blocks and character sets (MS-JIS).
- De-emphasis as an option, with the encoded file checked against the de-emphasized samples.

## CLI finish — done

- `Settings` (`~/Library/Application Support/CDRip/settings.json`), shared with the app: every key may be missing and has a default. `cdrip config` shows, gets, sets (dotted keys such as `aac.bitRate`, checked by decoding), unsets, and resets. Options on the command line override the file.
- Encoder options: AAC mode (`cbr`, `abr`, `vbr-constrained`, `vbr`), bit rate, and VBR quality, through AudioToolbox's bit rate control mode; MP3 mode (`vbr`, `cbr`, `abr`), preset, bit rate, and extra `lame` options.
- `plainPunctuation`: typographic quotes, dashes, the ellipsis, and the no-break space become ASCII in names and tags, as in the user's library ("Walkin' Blues").
- Progress: `RipEvent` from `AudioReader`, `TrackRipper`, and `SecureRipper` (each read's sectors, C2 and unreadable sectors, and each round of re-reads), for a progress line now and the app's live graph later. In a terminal, `cdrip rip` shows one status line that changes in place.
- Rips go in `~/Music/CDRip Rips` (the `rips` setting), not the current folder: not in the library (music apps would import the WAV files), nor a temporary folder (a rip is kept for repairs). After `rip --encode`, a rip that is all verified and encoded is deleted, file by file (only the files the rip wrote, then the folder if it is empty); `--keep-rip` keeps it. Encoding puts the rip report in the album folder as `Rip Report (Disc N).json`. The status line shows the track's elapsed time and the time left in the read.
- Help for every command, with examples; `cdrip --version`; `make release` (Apple silicon and Intel), `make install` and `make uninstall` with `PREFIX`, and shell completions for zsh, bash, and fish; the README.

- A drive report (`cdrip drives -d diskN --report`, later the app's bug-report tool): `DriveReport` holds the drive's registry (device and protocol characteristics, such as "CD Features", "Retry Count" 20, and "Read Time Out Duration" 30000 ms, and the USB bridge's names and IDs, with no serial numbers), the Mac and macOS, CDRip's profile of the drive, the disc's TOC and disc ID (no audio), and 7 quick checks with the disc in it: the TOC, a read of 2,600 sectors (speed), C2 flags, the Q subchannel, a read past the lead-out, CD-Text, and the cache size. About 10 seconds. From it, a drive that the developer does not have can be modeled in `SimulatedDrive`. Checked on the MATSHITA: its enclosure's bridge is an Initio chip (USB 0x13FD:0x0840).
- `cdrip cdtext -d diskN`: every field of the disc's CD-Text (titles, performers, songwriters, composers, arrangers, messages, disc ID, genre, UPC and ISRCs, the blocks' languages and character set), with `--packs` for the raw packs and `--json`.
- `cdrip eject -d diskN` (or `--all`): unmounts and ejects the disc through DiskArbitration, as the Finder does. Version 0.2.
- Ctrl-C during `rip` or `repair` stops after the read under way, keeps the tracks done so far, and releases the folder's claim; a second Ctrl-C ends the process at once.

Still to do:

- A check in the drive report of how the drive fails on an unreadable sector (it needs a damaged disc).
- Developer ID signing and notarization, with the user's new developer ID.

The rip and repair workflows are in the engine (`DiscRip`, `RipRepair`), and the CLI only prints their events, so the app can use the same code.

## Code review of 0.2 — done

Before the app, the whole engine and CLI were reviewed (`docs/Review-0.2.md`: 22 findings, 19 fixed and one in part, each fix with a test; items 21 and 22 belong to the app). The changes that matter most:

- The cache flush reads inside a track when there is no room outside it (a disc with one track), away from the suspect sectors and a read-ahead margin; it stays in the disc's audio areas (`TOC.audioAreas`), so on an enhanced CD it never reads the data session.
- A sector that could not be read has no version until a read gets it, and a version must come back twice to decide a sector. Two shifted reads agree only when no run of 32 sectors differs. A track that no later read confirms is suspect.
- Lookups are best effort: a failed AccurateRip or CTDB lookup leaves that check out, and the rip goes on.
- A rip can be stopped (`StopToken`, or by cancelling the task), its reads and encoding run on a thread of their own (`blocking(_:)`), its events are `Sendable` and carry sector positions for a live graph, and its report lists the files it wrote.
- `lame` exiting early no longer ends the process (SIGPIPE); the tag readers throw on short files; a CTDB entry with more than 16 syndromes is left out.

## Loose ends

Built and tested with the simulator, but not yet on hardware:

- The review's changes to the secure rip (the flush inside a track, the shifted-read agreement test, unreadable sectors as unresolved) and to the threads: one short rip of a clean disc and one of a damaged disc, and one `cdrip repair` with the disc in a drive, to check that the output did not change.

- The workflows in the engine (`DiscRip`, `RipRepair`): one short rip and one repair on a drive, to check that the output did not change.
- The prompt for a release when the ranking cannot pick one (a disc in several releases with no MCN, barcode, or earlier choice to settle it).
- Shifted-read detection (`SecureRipper`), made after *One from the Vault* disc 2 on the ASUS.
- Hidden track one audio: a disc with a real hidden track.
- Enhanced CDs (a data track in a later session): the AccurateRip and CTDB rules are marked as not verified in the code.

Discs that are not yet fully verified:

- *Hundred Year Hall* disc 1: 9 of 11 tracks; 4 CTDB columns have too many suspects.
- *Live/Dead*: 2 of 7 tracks.

Deferred:

- CTDB entry order. `DiscRepairer` tries entries by their submissions, and up to three shifts for each. On *Reckoning* (2026-10-21), the 31-submission entry, which is another pressing's, was tried at three shifts first, each a repair that stopped after 200 columns, before the 19-submission entry repaired the disc at shift 0 with no errors in column 0. Ordering every (entry, shift) pair by the errors in column 0 first (an exact match before any with errors), then by submissions, would try the right one first and save a minute or two on such discs.
- Discs that MusicBrainz does not know: names from CD-Text, or typed in (see the README's TODO).
- CD-Text in other blocks and character sets (MS-JIS).
- De-emphasis as an option.
- The drive report's check of an unreadable sector (it needs a damaged disc).
- Developer ID signing and notarization.
- A test of `RipRepair` without the network: it downloads AccurateRip and CTDB data itself. `DiscRepairerTests` covers the repair.

## 9. Multi-disc releases and style recipes

- A multi-disc release is one unit of work, so metadata stays consistent across discs and sessions.
- Apple Foundation Models for verification and cleanup of metadata from conventional sources only, with a non-AI path.
- Reusable style recipes, such as segue `>` marks and `[Venue, date]` suffixes.

## Later: DVD-Audio and Blu-ray audio

A possible goal after the CD work: extract the audio from a DVD-Audio disc (the user has *American Beauty*) and from a Blu-ray audio disc (a BD-R copy of *The Dark Side of the Moon*). These are different from CD: files on a UDF file system, MLP or PCM streams, and, on DVD-Audio, CPPM copy protection.

## The app (after the CLI)

What the engine gives the app, after the 0.2 review: `DiscRip.run()` and `RipRepair.run()` are async, run their reads on a thread of their own, and send `Sendable` events from that thread (`events` is `@Sendable`), so the app awaits them from any task and sends each event to its main actor. A Stop button cancels the task or calls `stop.stop()`; `run()` throws `CancellationError` after the chunk under way, and the folder keeps the tracks written so far. `RipEvent.reading` carries each chunk's sectors (counted from the track's start) and the flagged and unreadable ones, and `.rereading` the suspect sectors, for the live graph. Two things to remember: the app runs under App Transport Security, and AccurateRip (`www.accuraterip.com`) and CTDB (`db.cuetools.net`, `p.cuetools.net`) are plain HTTP, so its Info.plist needs exception domains for them; and a whole-disc repair holds the audio and several copies of it, two to three GB for an 80-minute disc, more with two drives at once.

- A simple ripping view by default: insert a disc, check the metadata, rip.
- All the technical detail is there to open on demand: everything the rip report has, for the disc (TOC, ISRCs, MCN, CD-Text, pregaps, flags) and for the rip.
- A live graph as each track rips: error levels by position, suspect sectors, and which were recovered or not. The engine sends progress events (sectors read, suspect, resolved, unresolved) as it works, so the graph, the progress display, and the rip report all come from the same events.
- Advice when tracks are not verified after the rip and the CTDB repair: the next step that is most likely to help. With the rip's suspects kept, a second rip in the same drive pools with the first (`--pool`); a rip in another drive helps more, because each drive reads damage differently (*Dick's Picks Vol. 2*, *Hundred Year Hall*); cleaning the disc helps when the errors are in many places. A disc that is not in AccurateRip or CTDB cannot be verified, only shown to read the same each time.

## Hardware for testing

| Drive | Connection | Read offset | Notes |
|---|---|---|---|
| MATSHITA BD-MLT UJ260AF | USB, no hub | +103 | The only offset that matches on all 3 test discs; agrees with the AccurateRip list (648 submissions). No overread. C2, Q subchannel, CD-Text, and ISRC work. |
| ASUS BW-16D1HT, firmware 3.10, possibly LG inside and modified for LibreDrive | USB | +6 | Agrees with the AccurateRip list (3,015 submissions); matches on *Dozin' at the Knick* disc 1. About 24.7×, the fastest so far. |
| HL-DT-ST BD-RE BU50N (LG), firmware CC03, possibly modified for LibreDrive (MakeMKV) | USB, no hub | +6 | Agrees with the AccurateRip list (51 submissions); matches on *Clarity of Cal*, with the same checksums as the MATSHITA at +103. No overread. C2 and Q subchannel (with user area) work. Raw P-W subchannel gives `EIO`. Reports 20×. |
| HL-DT-ST DVDRAM GUC0N (LG slim DVD writer in a generic enclosure), firmware AS01 | USB | +6 | From the AccurateRip list; *Reckoning* matches at +6 (2026-10-21): 15 of 15 accurate in 21 minutes, 4 tracks repaired by CTDB (6,452 samples; track 13 was accurate on the first read, which no other drive managed), every file identical to the archive. Slow: 6× (the others 20–25×). C2 flags, Q subchannel, and the cache (latest read only) as the others; no overread. |

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
- Grateful Dead, *Dick's Picks Vol. 8*, discs 1–3 (11, 5, and 8 tracks): heavily played, with black paint on the label side, but clean. Every track accurate on the first read, in all three drives at once. CTDB verifies each disc at another pressing's alignment (shifts −268, −869, −860), with 299 to 318 submissions.
- Grateful Dead, *Hundred Year Hall*, two discs (11 and 4 tracks), lightly cleaned: light to moderate damage. See the repair results in milestone 7.
- Grateful Dead, *Live/Dead*: **damaged**. Only track 7 (35 s) accurate on the ASUS; tracks 2 and 6 have C2 errors. MCN 0075990183026. 32 silent sectors before track 1. Seven pressings in AccurateRip.
- Grateful Dead, *Europe '72*, discs 1 and 2 (MCN 0075990266828 on both): **damaged**. Disc 1 on the MATSHITA: 3 of 10 tracks accurate in the first rip, with 557 bad Q frames in track 5 alone. A second rip of tracks 5 and 6 was accurate: the first rip differed in only 2 sectors and 1 sector, and a C2 scan (a separate read) found no errors there. So some errors happen on one read only, and re-reading fixes them. The other failed tracks have C2 errors on every scan: track 9 the most (250 sectors, 21,188 bits), then 10, 1, 2, and 8; damaged frames hide the start of track 6's pregap (it starts at 117938). Disc 2 on the HL-DT-ST: 2 of 7 accurate. Pregaps of 0.4–2.9 s, and 33 silent sectors before track 1 on both.
- Cory Wong, *Lost in the Wonder* (indie, no label shown): all 12 tracks accurate on the ASUS. One AccurateRip record, v2 only (4 submissions).
- The Who, *Live at Leeds* (2001 deluxe edition), both discs: all tracks accurate (20 on the HL-DT-ST, 13 on the MATSHITA), up to 200 v2 submissions. ISRCs on every track (GBAKW01… and GBAKW70…). Long pregaps on the 13-track disc: 12 s before track 10, 24 s before track 13.
- *Civilization IV* soundtrack (2005): 18 of 18 accurate; every pregap exactly 2.00 s. Track 4 has far fewer matching submissions than the others.
- Beatles, *The 1968 Demos* (Vigotone VIGO 100, Australia 1993; MusicBrainz lists it as a US 1994 bootleg): damage on the label side near the outer edge. 23 of 26 tracks proved free of errors (10 accurate, 13 matching another pressing at −688); tracks 21, 25, and 26 unresolved.
- Grateful Dead, *Two from the Vault*, both discs: all tracks accurate (5 and 4).
- Mac OS 8: a data-only disc (HFS, which current macOS cannot mount). `info` and `rip` say there are no audio tracks.
- Still to find: an enhanced CD, a disc with hidden track one audio, a pre-emphasis disc, and a scratched disc.
