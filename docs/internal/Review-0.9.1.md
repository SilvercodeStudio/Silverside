# Review fixes for 0.9.1 (2026-10-28, overnight)

The four open findings from the reviews of `6fa54c3..9da2a71` and of `41feac0`/`f184662` (0.9). Each one now has the reviewer's reproduction as a test in the suite, and the reviewer's own files (`/private/tmp/ss-9da2a71-review-repros.swift`, `/private/tmp/ss-f184662-review-repros.swift`) pass when copied into the tests (removed again afterward). All changes are unstaged.

| # | Finding | Status |
|---|---|---|
| 1 | P1: Save Data Track overwrites files in the album folder | Fixed |
| 2 | P1: an Apple partition map with 2048-byte blocks makes the data track's readable tail zeros | Fixed |
| 3 | P2: an update to a legacy report (nested `ripReport`) writes the root, and the copies disagree | Fixed |
| 4 | P2: Stop during the CTDB repair data's download still loses the rip | Fixed |

Checks: `make format` and `make lint` clean, 391 engine tests pass (4 new), the app builds with no warnings. No hardware test. The partition map rule was also checked against the three real data track images in the library (below).

## 1. Save Data Track overwrites files

`DiscEncoder.dataTrackConflicts(_:reportAt:)` (Encoding.swift) lists the files that Save Data Track would replace in the album folder but that the rip's encoding did not put there: an image, or the folder of its files, whose name is not in the report's `encoding.dataTrackFiles`. It covers both paths, a rip folder whose rip was encoded and a report kept in the library, and every image name the save writes (the names change from "Data track" to "Data track N" when a second data track joins). `saveDataTrack` throws `EncodingError.exists` before it reads the disc when there is one and `overwrites` is not set. The disc-part suffix moved into `DiscEncoder.discPart(of:)`, shared by both.

The app asks first (`AppModel.saveDataTrack`): "Replace the data track files in the album folder?" with the names, Replace or Cancel; Replace sets `overwrites`.

Test: `EnhancedCDTests.savesADataTrackOverOtherFilesOnlyWhenAsked` (the reviewer's case, both report paths, then with `overwrites`).

## 2. Apple partition maps with 2048-byte blocks

`DataTrackReader.appleMapEnd(of:)` (DataTrack.swift) reads the map as Apple's partition scheme does: the block size from the driver descriptor ("ER", `sbBlkSize`), 512 without one; entries ("PM") at blocks 1 on; start and count in those blocks. It gives no end (`.uncertain`, so `fileSystemEnd` returns nil and the whole track is read) when a descriptor's map is not where its block size puts it, when the map has more entries than the 26 sectors read hold, or when an entry is not an entry. Before, entries were taken at 512 bytes only and a bad entry was skipped.

Checked against the library's three images (same ends as before):

| Disc | Descriptor | Map's end | ISO's end | Track |
|---|---|---|---|---|
| Calexico | 512-byte blocks | 100,798 | 100,798 | 100,950 (152 skipped, as ripped) |
| *Mirrorball* | 512-byte blocks | 27,091 | 27,091 | 27,393 |
| *A Clockwork Orange* | none, no map | — | 6,395 | 6,697 (302 skipped, as ripped) |

Test: `EnhancedCDTests.readsAnHFSPartitionIn2048ByteBlocks` (the reviewer's case: 60 sectors skipped, the Mac payload at sector 200 kept; plus a descriptor with no map at its block size, and a map with more entries than were read, both nil).

## 3. Legacy nested reports

`RipReport.update(reportAt:_:)` writes into "ripReport" when the file has one, as `Encoding.save(inReportAt:)` and `RipCheck` already did, and writes only the keys the change changed. So a manifest's "release" beside its report, which `read` fills in, does not get copied into the report. A plain report is written as before, less its unchanged keys. `read`'s doc comment had slid onto `update`; it is back on `read`.

Test: `EncodingTests.updatesTheReportInsideAManifest` (the reviewer's case).

## 4. Stop during the repair data's download

`DiscRip`'s CTDB step treats a stop that comes as URLSession's `URLError.cancelled`, or any error once the stop token is set (a cancelled task sets it), as the stop it is: the rip is kept as not checked by CTDB, and `run()` then throws `CancellationError`.

Test: `DiscRipTests.keepsTheRipWhenStoppedDuringTheRepairDataDownload` (the reviewer's held URLSession request).

## For the morning review

- **Version 0.9.1 started.** `SilversideVersion.string` and the app's `MARKETING_VERSION` are 0.9.1, and the CHANGELOG has a "0.9.1 (not released yet)" entry with these four fixes. Undo the version strings if you would rather bump them yourself.
- **Save Data Track asks, not refuses.** The engine refuses; the app shows a Replace/Cancel alert first. A leftover `Data track` folder from an earlier save whose report no longer lists the image also counts as not the rip's, so it asks then too.
- **An uncertain partition map reads the whole track.** That is the safe side for the audio (the data track is read after the music) but brings back the post-gap read for such discs, the read that hung the ASUS. None of the three real discs is affected.
- `CLAUDE.md`'s data track bullet now names the block-size rule.
