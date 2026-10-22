# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

CDRip is a native macOS CD ripper. The goal is ripping quality equal to or better than Exact Audio Copy (EAC), with a modern UI and MusicBrainz-first metadata. It encodes to FLAC, ALAC, AAC, AIFF, and WAV, and to MP3 through an external `lame`.

The work is done in layers: engine library (`CDRipKit`), then a `cdrip` CLI, then the SwiftUI app (`App/`: `CDRip.xcodeproj` and its sources in `App/CDRip/`). The CLI is finished for daily use; the app is next (see **App** below).

Ripping is verification-first: rip fast with offset correction, verify each track against AccurateRip and CUETools DB (CTDB), and do secure re-reads only for tracks that don't match.

## Commands

Open `CDRip.xcworkspace` in Xcode: it has the app project and the `CDRipKit` package, with schemes for the app, `cdrip`, and the engine tests.

```sh
make cli ARGS='info'   # build and run the cdrip CLI (drives, info, cdtext, rip, repair, metadata, encode, config, eject; -d diskN)
make install PREFIX=~/.local   # universal release build of cdrip, and shell completions (make install-cli-local does the same)
make install-app               # universal release build of the app, copied to ~/Applications (APP_DIR=... for another folder)
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

## Architecture

The engine does the work, and the CLI only parses options and prints. Put new behavior in `CDRipKit`, so that the app gets it too. Engine files (`CDRipKit/Sources/CDRipKit/`), by layer:

- **Disc and drive:** `CDDA` (constants), `TOC`, `DiscIDs` (MusicBrainz, AccurateRip, freedb, CTDB), `Drive` (`CDDrive`), `SimulatedDrive`, `QSubchannel`, `SubchannelCodes` (MCN, ISRC), `PregapFinder`, `CDText`, `CacheProbe`, `DriveProfile` (`DriveProfileStore`), `DriveOffsetList`, `DriveReport`. The Darwin target (`CDRipDarwin`) has `IOKitDrive` and `OpticalDrive` (the drive list from the I/O Registry).
- **Reading:** `AudioReader` (offset correction, cache flush), `TrackRipper` (one pass, AccurateRip check), `SecureRipper` (re-reads, C2, shifted reads), `HiddenTrack`, `RipEvent` (progress).
- **Verification and repair:** `AccurateRipChecksum`, `AccurateRipOffsetFinder`, `AccurateRipRecord` and `OnlineLookup` (AccurateRip and CTDB downloads), `CTDB`, `GaloisField16` (with `ReedSolomonDecoder`), `DiscRepairer` (with `TrackAudio`, the suspects).
- **Metadata:** `WebClient` (rate limits, cache, retries), `MusicBrainz`, `ReleaseChoice` (`ReleaseRanking`, `ReleaseChoiceStore`), `ReleaseLookup`, `CoverArt`, `NameTemplate`, `TrackMetadata`, `MetadataEdits` (the user's changes to names, `ReleaseEditsStore` by release ID, and `MusicBrainzRelease.manual` for discs MusicBrainz does not know).
- **Output:** `WAVFile`, `AudioEncoder`, `EncoderOptions`, `MP3` (lame and ID3), `FLACTags`, `MP4Tags`, `ChunkTags` (AIFF and WAV), `EmbeddedCover`, `CueSheet`, `RipReport` and `RipReportMarkdown`, `Encoding` (`RippedDisc`, `DiscEncoder`).
- **Workflows:** `DiscRip` (a whole rip, as `cdrip rip` does it), `RipRepair` (`cdrip repair`), `RipPool` (earlier rips, and `RipFolder` claims), `RipSummaries` (text for people), `Settings`.

## App

The app is in `App/` (`CDRip.xcodeproj`, sources in `App/CDRip/`) and links the local package's `CDRipKit` and `CDRipDarwin` products. It is a first version (2026-10-21): the main window rips a disc end to end through `DiscRip`, and Settings edits the shared settings file and the drive profiles. The design (a Claude Design artifact; its PDF and icon assets are in `docs/asset_import/`) is an inspiration, not a spec. What is built, and what is not yet, is in `docs/Milestones.md` under **The app**.

Layout of `App/CDRip/`:

- `CDRipApp.swift`: the scenes (main window, Settings) and `AppCommands.swift` (the Disc menu).
- `Model/`: `AppModel` (settings, drives, earlier rips and their sets, the DiskArbitration watcher, the repair), `DriveSlot` (one drive: its disc, its rip, the choices for the next rip), `DiscInfo` (TOC, MCN, CD-Text, the MusicBrainz release and cover), `RipRun` (one rip: the engine's events turned into track states, progress, and a log), `RepairRun` (one repair: `RipRepair` with the pool and the drive), `DriveTestRun` (`DriveReport` and `CacheProbe` from Settings), `RecentRip` (earlier rips from `disc.json`), `Background` (the Dock tile's progress bar, the notification when a rip ends), and the debug-only `DemoDisc` and `DebugScreenshot`.
- `Views/`: `MainWindow` (split view, sidebar, empty states), `DriveDetailView` (toolbar, options popover, album header, status bar, result banner), `TrackTable`, `DiscGraph` (the disc by position, live or from a report), `ResultsView` (an earlier rip, with its Markdown report and Repair), `Sheets` (release picker, rip log, repair, drive test), `SettingsView` (General, Drives, Ripping, Encoding, Naming), `HelpWindow` (the Help window, a small Markdown-to-HTML converter, a WebKit view), `Theme` (the sheen gradient, chips, progress bar, cover).
- `Help/`: the help pages as Markdown (`NN Title.md`; the number orders them, the first heading names them). The synchronized folder bundles them as resources.

Rules for the app:

- Put behavior in the engine. The app only turns engine types into views; when the app needs something the engine lacks (a public init, `Identifiable`), add it to `CDRipKit`.
- The target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: every type is main-actor unless marked `nonisolated`. Engine work runs in `Task.detached`; the engine's `@Sendable` event closures hop back with `DispatchQueue.main.async` + `MainActor.assumeIsolated`, which keeps the events in order. Build the drive (`IOKitDrive`, `SimulatedDrive`) inside the detached task: `any CDDrive` is not `Sendable`.
- A disc is read (TOC, MCN, CD-Text) when it appears, then looked up in MusicBrainz once (the web cache keeps the answer, so the rip's own lookup sends no second request). The rip gets the chosen release by ID.
- **Edits to names** live in `MetadataEdits`, never in a changed `MusicBrainzRelease`: the release in `disc.json` is what MusicBrainz said, "edits" sits next to it, and `RippedDisc` applies them for the encoder. The album-level edits are kept by release ID (`ReleaseEdits.json`), so the other discs of a set get them; `DiscRip` reads that store and writes to it. A disc with no release gets `MusicBrainzRelease.manual` (ID `cdrip:<disc ID>`): no MusicBrainz IDs in the tags, no cover download, not remembered as a choice.
- Info.plist has the App Transport Security exceptions for AccurateRip and CTDB (plain HTTP). It sits in the synchronized folder with a membership exception, so it is not copied as a resource.
- The app icon is `Assets.xcassets/AppIcon.appiconset` (the design's "icon set v2": B2 at 128 px and up, C2 below). `AppIconLarge` and `AppIconOverhead` are the 1024 px images for use in views. An Icon Composer `.icon` for macOS 26+ is still to do.
- Debug launch arguments take a value (`UserDefaults` reads `-key value` pairs, so a bare `-flag` swallows the next argument): `-demo 1` adds a simulated drive with a short disc (release from the engine's *Cornell 5/8/77* fixture, offline); `-demoOnly 1` leaves the real drives alone; `-demoRip 1` starts the demo's rip (about 2 minutes in a debug build); `-screenshotPath /path.png -screenshotDelay 6` renders the windows to PNG (one file per window) and quits; `-openWindow settings -settingsTab drives`, `-driveTest test|cache` (runs the check of the demo drive), `-ripOptions 1` (opens the options popover), `-selectRecent 1` (shows the newest earlier rip) and with it `-repair 1` (starts its repair). `make run ARGS='-demo 1 -demoOnly 1'` runs it. The sidebar does not render in the offscreen capture (its material draws only on screen), but the content does. To try a repair without touching the user's rips, copy a rip into a scratch folder and point `CDRIP_SETTINGS` at a settings file whose `rips` is that folder.
- A repair (`RipRepair`) writes a report: into the rip's own folder when CTDB verifies the rip as it is, else into the "… repaired" folder with the files that are not audio copied along, so that folder is a rip like any other. `RipReport.advice` is the text after an unverified rip; `RipSet` groups earlier rips of a multi-disc release.
- Running the app with a disc in a real drive reads that disc's TOC and MCN at once. Ask before a test that needs a drive.
- `-openWindow help` opens the Help window at launch. WebKit draws out of process, so a screenshot shows the Help window's title but not its page; check the converter's HTML instead.

## Engine conventions (CDRipKit)

These rules apply in many files. Errors here give results that are a few samples wrong, and no test fails on real discs until much later.

- **A "sample" is one stereo frame**, as in AccurateRip and EAC: a `UInt32` with the left 16-bit value in the low half. This is the little-endian byte order that drives return. There are 588 samples in each 2352-byte sector.
- **LBA 0 is MSF 00:02:00.** `TOC` stores LBAs. MusicBrainz and freedb offsets add the 150-sector lead-in (`CDDA.leadInSectors`).
- **Read offset sign:** a drive with offset +N (as AccurateRip lists it) returns data N samples *earlier* than the sector asked for. `AudioReader` corrects this. Without overread, it fills samples past the disc edges with silence. AccurateRip ignores those samples, because it skips the first 2939 samples of the first track and the last 2940 of the last track.
- **Enhanced CDs** (a data track in a later session): the audio session ends `CDDA.sessionGapSectors` (11400) before the data track. MusicBrainz leaves out the data track. AccurateRip uses the real lead-out and counts audio tracks only.
- **Track ranges** run from one track's index 01 to the next track's index 01, so a pregap belongs to the track before it.
- **Times** print as `MM:SS:FF` (frames of 1/75 second), as in CUE sheets, so they cannot be read as decimal seconds.
- **Q subchannel:** frames can be damaged, so check `isValid`. `PregapFinder` reads around damaged frames, and MCN or ISRC frames (about 1 in 100). A damaged frame just before a change leaves the change unknown by one sector, so it throws for that track only.
- **Re-reads need a cache flush.** Drives return cached data for a re-read in under 1 ms. `AudioReader.flushCache(awayFrom:)` reads in the disc's audio areas away from the ranges it is given (plus a read-ahead margin), because a read of a damaged sector there counts as one of its re-reads: `SecureRipper` passes the whole track before a full read again, and only the suspect runs before a round of re-reads, so a disc with one track still gets a flush. The flush size comes from the drive's profile (`cdrip drives --measure-cache`); all three test drives keep only the latest read, so 256 sectors is plenty, and the default for an unmeasured drive is 4,000.
- **Audio areas.** `TOC.audioAreas` lists the sectors a drive reads as audio: no data track, no session gap. `AudioReader` reads only there and fills the rest with silence, as past the disc's edges. `SimulatedDrive` fails reads elsewhere, as hardware does.
- **Stopping, threads, and lookups.** Long reads and CPU-heavy decoding go inside `blocking(_:)`, so no cooperative-pool thread is held; the code checks `StopToken` between chunks, rounds, and tracks, and throws `CancellationError`. A failed AccurateRip or CTDB lookup sends `.lookupFailed` and the rip goes on as not checked; only a drive with no offset at all needs the drive offset list.
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
8. Mostly done: the Markdown rip report, CUE sheets, pregaps, CD-Text (`cdrip cdtext`), hidden track one audio, AIFF and WAV tags; and the drive report (`cdrip drives --report`).

The CLI is finished for daily use. Next: the app. The loose ends (built but not tested on hardware, and deferred work) are in `docs/Milestones.md`.
