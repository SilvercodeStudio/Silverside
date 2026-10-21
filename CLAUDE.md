# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

CDRip is a native macOS CD ripper. The goal is ripping quality equal to or better than Exact Audio Copy (EAC), with a modern UI and MusicBrainz-first metadata. It encodes to FLAC, ALAC, AAC, AIFF, and WAV. MP3 is out of scope.

The work is done in layers: engine library (`CDRipKit`), then a `cdrip` CLI, then the SwiftUI app (`App/`: `CDRip.xcodeproj` and its sources in `App/CDRip/`). The app doesn't link `CDRipKit` yet.

Ripping is verification-first: rip fast with offset correction, verify each track against AccurateRip and CUETools DB (CTDB), and do secure re-reads only for tracks that don't match.

## Commands

Open `CDRip.xcworkspace` in Xcode: it has the app project and the `CDRipKit` package, with schemes for the app, `cdrip`, and the engine tests.

```sh
make cli ARGS='info'   # build and run the cdrip CLI (drives, info, rip, repair, metadata, encode, config; -d diskN)
make install PREFIX=~/.local   # universal release build of cdrip, and shell completions
swift build --package-path CDRipKit -c release --product cdrip   # CTDB repair needs the release build to be fast
make test        # swift test --package-path CDRipKit
make hwtest OFFSET=103   # hardware tests; needs a disc in AccurateRip (DEVICE=diskN to choose; OFFSET checks the drive's offset)
make core        # swift build --package-path CDRipKit
make build       # xcodebuild the app (CONFIG=Release for a universal build)
make run         # build and start the app; ARGS='...' passes launch arguments
make format      # swift-format in place (.swift-format: 4 spaces, 120 columns)
make lint        # swift-format lint --strict; must be clean
```

To run one suite or one test (Swift Testing):

```sh
swift test --package-path CDRipKit --filter AudioReaderTests
swift test --package-path CDRipKit --filter 'DiscIDTests/ctdbTOCString'
```

Run `make format`, `make lint`, and `make test` before you report work as done.

## Engine conventions (CDRipKit)

These rules apply in many files. Errors here give results that are a few samples wrong, and no test fails on real discs until much later.

- **A "sample" is one stereo frame**, as in AccurateRip and EAC: a `UInt32` with the left 16-bit value in the low half. This is the little-endian byte order that drives return. There are 588 samples in each 2352-byte sector.
- **LBA 0 is MSF 00:02:00.** `TOC` stores LBAs. MusicBrainz and freedb offsets add the 150-sector lead-in (`CDDA.leadInSectors`).
- **Read offset sign:** a drive with offset +N (as AccurateRip lists it) returns data N samples *earlier* than the sector asked for. `AudioReader` corrects this. Without overread, it fills samples past the disc edges with silence. AccurateRip ignores those samples, because it skips the first 2939 samples of the first track and the last 2940 of the last track.
- **Enhanced CDs** (a data track in a later session): the audio session ends `CDDA.sessionGapSectors` (11400) before the data track. MusicBrainz leaves out the data track. AccurateRip uses the real lead-out and counts audio tracks only.
- **Track ranges** run from one track's index 01 to the next track's index 01, so a pregap belongs to the track before it.
- **Times** print as `MM:SS:FF` (frames of 1/75 second), as in CUE sheets, so they cannot be read as decimal seconds.
- **Q subchannel:** frames can be damaged, so check `isValid`. `PregapFinder` reads around damaged frames, and MCN or ISRC frames (about 1 in 100). A damaged frame just before a change leaves the change unknown by one sector, so it throws for that track only.
- **Re-reads need a cache flush.** Drives return cached data for a re-read in under 1 ms. `SecureRipper` reads far from the track first, and never inside it, because a read of a damaged sector there counts as one of its re-reads. The flush size comes from the drive's profile (`cdrip drives --measure-cache`); all three test drives keep only the latest read, so 256 sectors is plenty, and the default for an unmeasured drive is 4,000.
- **Files that several versions share** (`DriveProfiles.json`, `settings.json`) keep keys they do not know: a save merges into the file's JSON (`JSONMerge`), and optional values are written as `null` so that clearing one still works. An older `cdrip` once erased the measured cache sizes of every drive this way.
- **Suspects** are samples that may be wrong: where reads disagree, or with C2 errors (294 flag bytes per sector, one bit per byte, bit 7 first; a hint only). `TrackAudio` holds them with their other values, and `Track NN.suspects` files keep them next to the WAVs, so `repair` can pool rips from several drives. A read that loses its place is shifted, not damaged: `SecureRipper` finds the shift and leaves the read out.
- **CTDB** (`CTDB.swift`, verified against real entries): the audio from the first audio track to the lead-out is 16-bit words (left, right, ...). Rows are 11,760 words (5,880 samples, 10 sectors; the XML `stride` counts samples). The first row, and the last row plus the remainder, are left out of the CRC and the repair data. The disc CRC is plain CRC-32 (zlib) of that middle part; track CRCs leave out the same parts in the first and last tracks. Each column is a Reed–Solomon codeword over GF(2¹⁶), polynomial 0x1100B, α = 2: S_i = Σ word × α^(i × degree), with the first row at the highest degree. The `hasparity` file holds syndromes (not parity), syndrome by syndrome, one value per column; the lookup's `syndrome` attribute is column 0's. **Entries can be stored at another pressing's alignment** (*Two from the Vault* disc 1: shift +1195), so find the shift from column 0's syndromes; `CTDB.column0Syndromes` gets every shift from two passes. Reed–Solomon can miscorrect past its limit, so always check the CRC after a repair.
- `CDDrive` is the hardware boundary. `IOKitDrive` (target `CDRipDarwin`) implements it with the `DKIOCCD*` ioctls on `/dev/rdiskN`. Swift does not import the `_IOWR` macros, so `Ioctl` computes the request codes, and a test checks them against the SDK. The node belongs to the console user, and the ioctls work while cddafs has the disc mounted. `SimulatedDrive` stands in for hardware in tests. It can simulate a read offset, overread, unreadable sectors (by requested LBA), and silent corruption (by physical sector). New drive behavior (cache, C2, subchannel, jitter) goes into both the protocol and the simulator, so you can test it without hardware.

## Verified vs. unverified

The test values in `DiscIDTests` are real data from MusicBrainz, AccurateRip, and CTDB. Don't change them to make a test pass.

- **Verified:** MusicBrainz disc IDs (all 20 discs of Grateful Dead *Summer Magic 1985*), AccurateRip disc IDs and URLs (two Nevermind pressings), CTDB TOC strings for audio-only discs, freedb IDs. With real hardware: the full-TOC parser, and AccurateRip v1 and v2 track checksums (track 5 of *Dozin' at the Knick* disc 1 at offset +103).
- **Not yet verified:** AccurateRip and CTDB rules for discs with data tracks. A code comment marks each one. Verify them on hardware before you remove the comment.

## Hardware findings

Three drives so far (MATSHITA UJ260AF +103, HL-DT-ST BU50N +6, ASUS BW-16D1HT +6); details for each are in `docs/Milestones.md`. MATSHITA BD-MLT UJ260AF on USB (no hub), probed with `DKIOCCD*` ioctls:

- The read offset is +103. It agrees with AccurateRip's drive offset list, and it is the only offset that matches on all three test discs. One disc cannot prove a drive's offset: other pressings match too, and they can have more submissions (*The Endless River*: +773 has v1 66 and v2 200, +103 has 27 and 200). AccurateRip confidences stop at 200. Find a drive's offset from the offsets that several discs share, or from the AccurateRip drive offset list.
- These work: full TOC, audio reads, C2 error flags, and Q subchannel together with the user area (Q alone gives `EINVAL`).
- No overread: reads at or past the lead-out give `EIO`. The HL-DT-ST BU50N (offset +6) gives the same result, so the limit may be in the macOS CD driver, not the drives. Exclusive SCSITask access would show which.
- The HL-DT-ST BU50N at +6 and the MATSHITA at +103 give identical checksums for the same track.
- Read MCN and ISRC from the Q subchannel (`SubchannelCodes`), not with `DKIOCCDREADISRC` and `DKIOCCDREADMCN`. On the HL-DT-ST, the ISRC ioctl returned the previous track's code for several tracks of *The Story of the Ghost*, and the code no longer uses either ioctl. MCN and ISRC frames are about 1 in 100 Q frames; in the 6-bit ISRC characters, `0`–`9` are 0x00–0x09 and `A`–`Z` are 0x11–0x2A.
- A valid MCN or ISRC frame can sit at a track change (*The Story of the Ghost*, LBA 17441). `PregapFinder` counts such frames as part of the previous track.
- C2 flags are a hint only. On damaged discs, the result for a sector can change between reads: *Reckoning* track 12 was accurate in a rip, but a later C2 scan found 3 bad sectors. Raw P-W subchannel can be unreliable too (MATSHITA, *Reckoning*).
- AccurateRip records can be v2 only (Vulfpeck *Clarity of Cal* has one v2 submission). The v1 offset search finds nothing there; the sector 450 checksum, which is v1-style for both versions, finds the offset.

## Constraints

- **Dependencies:** discuss each outside dependency with the user before you add it. Today the only one is swift-argument-parser, for the `cdrip` target only; the engine targets have none. MP3 output will use `lame` (agreed with the user) as an external program through a pipe, never linked. Prefer Apple frameworks: AudioToolbox encodes FLAC and ALAC, CryptoKit does SHA-1, and URLSession, IOKit, and DiskArbitration cover the rest.
- **Licensing:** the project will probably be open source under a permissive license such as MIT. Don't port GPL code. You may read whipper, libcdio-paranoia, XLD, and CUETools to understand an algorithm, but write our own implementation.
- **Distribution and access:** the app uses Developer ID distribution, not the App Store. App Sandbox is off, because ripping needs raw device access.
- **Platform versions:** Swift 6 language mode. The package and the app both require macOS 15 Sequoia. Don't use APIs from later releases without `if #available`: for example `Span` (macOS 26), and Foundation Models (macOS 26), which must stay optional. The tests run only on the current macOS here, so read the availability of each new API.
- **Network services:** MusicBrainz is central to the project, so protect access to it. Its limit is 1 request per second on average per IP address, with a descriptive User-Agent; it answers 503 when a client goes too fast. **Do not query MusicBrainz in ad-hoc scripts** during development: use the release data already saved in `~/Music/CDRip Archive/*/disc.json`, or saved responses in test fixtures. All requests go through `WebClient` (a rate limit per host across processes, retries on 503, a cache in `~/Library/Caches/CDRip/`); MusicBrainz requests go through `MusicBrainzClient`, one request per disc. Keep the number of requests low: use the cache and saved fixtures, and ask the user before a batch of more than a few discs. Never put the user's email address in requests. AccurateRip and CTDB are less strict, but avoid repeating the same lookups.
- **Hardware:** usually no drive is attached. The user has several external USB drives and a test kit of discs. Ask before you start work that needs one.

## Roadmap

The full list is in `docs/Milestones.md`. Keep both up to date.


1. Done: TOC, disc IDs, AccurateRip checksums, simulated drive, offset-corrected reader.
2. Done: `IOKitDrive`, hardware tests, and the `cdrip` CLI with `drives` and `info` (TOC, pregaps, IDs, ISRC, MCN, AccurateRip and CTDB status).
3. Done: `cdrip rip` (offset-corrected WAV, AccurateRip result per track), drive profiles, and AccurateRip's drive offset list.
6. Done, ahead of 4 and 5 because the user has many damaged discs: `SecureRipper` (cache flush, re-reads of suspect sectors, C2, unreadable sectors, shifted reads, combinations tested against AccurateRip).
7. Done: CTDB verification and repair (`CTDB`, `ReedSolomonDecoder`, `DiscRepairer`), in `cdrip rip` and in `cdrip repair` (from ripped WAV files, pooling several rips, with re-reads when the disc is in a drive). `rip` writes a `RipReport` as `disc.json`.
5. Mostly done: metadata (`MusicBrainzClient`, `ReleaseRanking`, `CoverArtClient`, `NameTemplate`, `cdrip metadata`; `rip` names its folder from the release).
4. Mostly done: encoding (`AudioEncoder`, `FLACTags`, `MP4Tags`, `ID3Tags`, `DiscEncoder`, `cdrip encode`, `cdrip rip --encode`), checked by decoding each file again.

The CLI is finished for daily use: settings (`cdrip config`), encoder options, progress, help, `make install`. Next: a drive report, then milestone 8 (Markdown report, CUE sheets), then the app.
