# Code review of CDRip 0.2

Date: 2026-10-20. Scope: the whole engine (`CDRipKit`), `CDRipDarwin`, the `cdrip` CLI, the tests, and the docs, before work on the app starts. Method: every file was read; the suspected secure-rip bugs were checked against `SimulatedDrive` with throwaway tests; one Foundation behavior was checked with a script. No drive or disc was used.

Baseline: `make lint` clean, 187 tests in 46 suites pass.

## Verdict

The foundation is solid. The sample and offset math, the AccurateRip checksums and sliding offset search, and the CTDB layout, Reed–Solomon decoder, and shift search read as correct and are backed by real-data tests. Network parsers are bounds-checked. The engine/CLI split is clean, and the workflows are already in the engine.

The problems sit at the edges of the secure-rip logic, in error handling, and in what the app will need. None blocks daily CLI use. Items 1, 5, 17, 18, and 21 matter most before the app.

## Findings

Status: **Fixed** (in this review's changes, with a test), **Open** (not done), **Deferred** (needs hardware, or belongs to the app phase).

### Confirmed with the simulator

| # | Finding | Status |
|---|---|---|
| 1 | **A one-track disc never gets a cache flush, and a wrong version can win.** `flushCache(awayFrom:)` reads only outside the track. When the track spans the disc, both regions are empty and it returns without reading. Re-reads then come from the drive's cache and repeat one version, which beats the other by the agreement margin. Test: one track, an unstable sector, a 100-sector cache, no AccurateRip: status "consistent", no unresolved sectors, and the chosen data was wrong. | Fixed |
| 2 | **An unreadable sector's silence counts as a read version.** `seedC2Sectors` adds the base block (silence) for unreadable sectors, and one version is "decided" at once. Test: a sector that always fails, no AccurateRip: status "consistent", zero rounds. The CTDB path still marks the samples suspect, so repair is unaffected, but the status and summary are misleading. | Fixed |
| 3 | **Two reads that slip differently are taken as agreeing with each other.** The agreement test is "no single shift explains the difference", which is also true for two different slips. The base is replaced by a shifted read and `firstReadWasShifted` is set. Test: slips on pass 2 and pass 3 at different sectors: the audio came out right after four rounds of 330 sectors, but the report says the first read lost its place. | Fixed |
| 4 | **Mixed-mode discs: the hidden-track rip reads the data track as audio.** `HiddenTrackRip` checks only that the first audio track starts after LBA 0. Test: a data track 1 of 3000 sectors gave a 3000-sector "hidden track". On hardware those reads fail, so the rip would retry the whole data track sector by sector. | Fixed |
| 5 | **A `lame` that exits early kills the process with SIGPIPE.** Foundation's `Pipe` does not set `F_SETNOSIGPIPE`. A script that wrote to the stdin pipe of an exited child died with status 141. A bad `--lame-option` or an unwritable output triggers it; in the app it is a crash. | Fixed |

### Found by reading

| # | Finding | Status |
|---|---|---|
| 6 | **Enhanced CDs: the cache flush reads the data session.** The `after` region ends at `leadOutLBA`, so for the last audio track the flush reads the data track: every read fails silently, costs the drive's timeout, and the cache stays full. `AudioReader.read` clamps to `leadOutLBA` too. Not verified on hardware (no enhanced CD yet). | Fixed |
| 7 | **No second read ever agreed, yet the status says "consistent".** If every extra read is shifted and no two agree, `readWholeTrack` returns with no versions, and the track is reported consistent. | Fixed |
| 8 | **Network failures abort a rip.** The drive offset list is downloaded even when the profile has an offset, and a failure there, or in the AccurateRip or CTDB lookup, throws before any track is read. MusicBrainz and cover art already degrade. Decision (Preston, 2026-10-20): continue as "not checked". | Fixed |
| 9 | **Possible crash on a CTDB entry with more than 16 syndromes.** `DiscRepairer` caps the candidate syndromes at 16 but `CTDB.shifts` indexes them by every index of the entry's column 0. | Fixed |
| 10 | **A malformed TOC can crash `sectorRange`.** `audioLeadOutLBA` is not checked against the last audio track's start, so an odd multi-session TOC gives an inverted range. | Fixed |
| 11 | **Tag readers index without bounds checks** (`FLACTags.readFrontCover`, `MP4Tags.read` and `freeformName`, `ID3Tags.readTextFrames`): a truncated file crashes instead of throwing. | Fixed |
| 12 | **`WAVFile.read` rejects WAVE_FORMAT_EXTENSIBLE**, and `RipPool` drops such files silently. Some rippers write the extensible form for 16-bit stereo. | Fixed |
| 13 | **`deleteRipFiles` can delete the user's own files**, and it deletes `Artwork/`, which encoding never copies to the library. With `--artwork all --encode`, the booklet scans are downloaded and then deleted. | Fixed |
| 14 | **The encoder checks for existing files one track at a time**, after earlier tracks were written, so a half-encoded album cannot be resumed without `--overwrite`. | Fixed |
| 15 | **The rate limiter blocks a thread.** `WebClient.waitForTurn` holds the file lock while it sleeps; a second in-process request to the same host blocks a cooperative thread in `flock` for the whole interval. | Fixed |
| 16a | `Settings.setting` parses the value as JSON first, so `config set library 2024` fails. | Fixed |
| 16b | `TrackRipper` falls back to a plain read on any error from the C2 read, including a disc ejected mid-track. A C2 probe per drive would be better. | Deferred |
| 16c | A profile is saved with a nil listed offset, so an unlisted drive fetches the list on every rip (from the cache). | Fixed |
| 16d | The status table at the top of `Milestones.md` is stale. | Fixed |
| 16e | AccurateRip and CTDB are plain HTTP, so forged data could mark a rip accurate. Low risk for audio checksums; note it in the README. | Fixed |

### Before the app

| # | Finding | Status |
|---|---|---|
| 17 | **No cancellation.** Nothing checks a stop flag; a Stop button needs a check between chunks and rounds, and a defined partial result. | Fixed |
| 18 | **Blocking reads inside async functions** hold a cooperative-pool thread for the length of a rip. Decision (Preston): move blocking work off the pool now. | Fixed |
| 19 | **Events are not `Sendable`** and the `events` closures are not `@Sendable`; the app must hop every event to the main actor. | Fixed |
| 20 | **The live graph needs positions, not counts.** `RipEvent.reading` carries counts of C2 and unreadable sectors. Decision (Preston): change `RipEvent` now. | Fixed |
| 21 | **App Transport Security.** The app runs under ATS; the CLI does not. AccurateRip and CTDB are plain HTTP, so the app's Info.plist needs exception domains. | Deferred to the app |
| 22 | **Memory.** A whole-disc repair holds the audio plus several copies: two to three GB for an 80-minute disc. | Deferred (note only) |

### Tests to add

- `SecureRipper`: a one-track disc with a cache; a sector unreadable once and readable later; two differently shifted reads; every extra read shifted; damage in a first or last track.
- `SimulatedDrive`: a sector that fails N times, a drive that refuses C2, reads in a data track that fail.
- `DiscRip` with lookups through a fake transport, so `apply`, the alternatives cleanup, `--pool`, and `.trackRepaired` are covered; each lookup failing.
- `RipRepair` end to end with a fake client.
- `HiddenTrackRip` on a mixed-mode TOC; `flushCache` on an enhanced CD.
- `TOC(fullTOC:)` with two sessions; a TOC with an invalid session gap.
- Tag readers on truncated input; `WAVFile.read` with a `LIST` chunk before `data` and the extensible format; `CueSheet` with a hidden track plus later pregaps.

## Changes made

Each entry names the finding, the files, and the tests. All 197 engine tests pass after each batch.

**Batch 1: secure-rip edges (items 1, 2, 3, 4, 6, 7, 10).**

- `TOC.audioAreas` (new): the sectors a drive reads as audio, less data tracks and the session gap. `TOC.init` now refuses an enhanced CD whose data track starts less than the session gap after the last audio track (item 10).
- `AudioReader.read` reads only inside the audio areas; samples elsewhere stay silence, as past the disc's edges (item 6). It also checks a `StopToken` before each chunk (the start of item 17), and `ReadProgress` now carries the chunk's drive sectors and the flagged and unreadable sectors in it (the start of item 20).
- `AudioReader.flushCache(awayFrom:)` takes a list of ranges, finds the free parts of the audio areas around them (less a 128-sector read-ahead margin next to each), and reads the largest first from its far end. With one track, the free parts are inside the track (item 1). The secure ripper's rounds now pass only the suspect runs, and `DiscRepairer.reread` passes every sector it re-reads. The flush throws only when stopped.
- `SecureRipper`: a sector that could not be read gets an empty version list, not silence; a version must come back twice to decide a sector (item 2). Two shifted reads agree only if no run of 32 sectors differs, not when no single shift explains the difference (item 3). When no later read agrees with the first, the status is `.suspect` with no unresolved sectors (item 7).
- `HiddenTrackRip` does nothing when track 1 is a data track (item 4).
- `SimulatedDrive`: `failingReads` (a sector that fails N times, then reads), and reads outside the audio areas fail, as on hardware.
- Tests: `SecureRipperTests.flushesInsideADiscWithOneTrack`, `readsAnUnreadableSectorAgainLater`; `ShiftedReadTests.doesNotTakeTwoDifferentSlipsForAgreement`, `isSuspectWhenNoReadConfirmsTheFirst`; `UnreadableSectorTests.leavesASectorThatNeverReadsUnresolved`; `HiddenTrackTests.leavesADataTrackAlone`; `AudioReaderTests.staysInTheAudioOfAnEnhancedCD`, `flushesInTheLargestGapFirst`; `TOCTests.audioAreasLeaveOutDataTracksAndTheSessionGap`, `rejectsADataSessionTooCloseToTheAudio`.

**Batch 2: crashes (items 5, 9, 11).**

- `MP3Encoder.encode` turns off SIGPIPE on its pipe (`F_SETNOSIGPIPE`, per descriptor, so nothing global changes), collects what `lame` says on a background handler so a full stderr pipe can never block it, and reports a write that fails as `lameFailed` with that message (item 5). Nothing changes for the CLI's startup.
- `DiscRepairer` leaves out an entry with more than 16 syndromes for each column, with a log line (item 9).
- `FLACTags.readFrontCover`, `MP4Tags.read` and its helpers, and `ID3Tags.readTextFrames` check every index: a short file throws `FLACError.malformed`, `MP4Error.malformed`, or the new `MP3Error.malformedID3Tag`, or skips the item (item 11).
- Tests: `MalformedTagTests` (four tests, one of them the encoder that exits at once, which used to end the process), `DiscRepairerTests.leavesOutAnEntryWithTooManySyndromes`.

**Batch 3: files (items 12, 13, 14).**

- `WAVFile.read` accepts the extensible form with the PCM subformat (item 12). `RipPool.versions` returns the track files it could not use, with the reason, and `DiscRip` and `RipRepair` send them as `.poolFileSkipped` events, which the CLI prints.
- `RipReport.files` (new) lists what the rip wrote, relative to its folder. `DiscRip` keeps the list as it writes (WAV files, suspects, artwork, the two reports) and now saves the artwork before it writes the report, so the `.artwork` event comes before `.finished`. `RippedDisc.deleteRipFiles` deletes the listed files and nothing else; for older rips without the list it falls back to the old names. `DiscEncoder` copies `Artwork/` into the album folder, as it did the cover (item 13).
- `DiscEncoder.encode` works out every track's names and checks for existing files before it writes any (item 14).
- Tests: `WAVFileTests.readsTheExtensibleForm`; `RipPoolTests.reportsTrackFilesItCannotUse`; `EncodingTests.deletesOnlyTheFilesTheRipListed`, `checksEveryFileBeforeWritingAny`; `DiscRipTests` checks the file list.

**Batch 4: lookups and settings (items 8, 15, 16a, 16c).**

- `DiscRip` fetches AccurateRip's drive offset list only when the drive has no offset from any source, and a failure there, in the AccurateRip download, or in the CTDB lookup sends a `.lookupFailed` event and leaves that check out: the report says "not in database" for AccurateRip (as for an offline rip) and "not checked" for CTDB (item 8). Since a drive with an offset no longer fetches the list, the profile is no longer saved with a nil listed offset on every rip (item 16c).
- `DiscRip.webClient` (new, `WebClient.shared` by default) is used for every lookup, download, and the cover art, so tests can give a fake transport.
- `WebClient.waitForTurn` holds the rate file's lock only while it reads or writes the time, and sleeps with the lock released, in a loop (item 15).
- `Settings.setting` tries the value as JSON and falls back to text when the setting does not take it (item 16a).
- Tests: `DiscRipTests.verifiesWithAccurateRipAndCTDB`, `repairsWithCTDBAndWritesTheTrackAgain` (the first tests of the online path: AccurateRip records, a CTDB entry with repair data, the repaired track written again), `goesOnWhenTheLookupsFail`; `WebClientTests.serializesRequestsFromSeveralTasks`; `SettingsTests.changesOneKey` (text that looks like JSON). `FakeWeb` in `TestSupport.swift` answers URLs by prefix.

**Batch 5: for the app (items 17, 18, 19, 20).**

- `StopToken` (new, `Synchronization.Atomic`): `DiscRip.stop` and `RipRepair.stop`, set from any thread. `AudioReader` checks it before each chunk and in the cache flush, `SecureRipper` before each round, `DiscRip` between tracks and before encoding, `DiscRepairer` between entries and rounds. A stop throws `CancellationError`; the folder keeps the tracks written so far, and the claim file goes. `run()` also bridges task cancellation to the token with `withTaskCancellationHandler` (item 17).
- `blocking(_:)` (new, `Blocking.swift`) runs long work on a concurrent GCD queue and awaits it, so a task that awaits `run()` holds no cooperative-pool thread. `DiscRip` uses it for the MCN read, the hidden track, each track's rip (with pooling and the file writes), and the encoding; `DiscRepairer` for the syndromes, the shift search, each decode of the columns, and the re-reads; `RipRepair` for the file reads, the extra reads, and the writes. The one `@unchecked Sendable` is the box that carries the closure to that thread (item 18).
- `DiscRipEvent`, `DiscRipResult`, and `RipRepairEvent` are `Sendable`; the `events`, `chooseRelease`, `log`, and `repairData` closures are `@Sendable`. The CLI's `RipPrinter` is `@unchecked Sendable`, since events come one at a time (item 19).
- `RipEvent.reading` carries a `ReadProgress` whose chunk and flagged and unreadable sectors are counted from the track's start (`ReadProgress.inTrack(startingAt:readOffset:)` converts from drive sectors; a drive sector that lies in two track sectors counts for both), and `.rereading` carries the list of suspect sectors. The CLI's status line shows the same text as before (item 20).
- `RipRepair.webClient` (new), as for `DiscRip`.
- Tests: `DiscRipTests.stopsWhenAsked` (by the token from an event, and by cancelling the task); `RipEventTests.reportsReadsAndRounds` (chunk positions and flagged sectors), `countsProgressInSectorsOfTheTrack`.

**Batch 6: more tests, and names (from the list).**

- `NameTemplate.name` never gives an empty name: empty parts are left out, and a name with nothing left is "Unknown", so files cannot land in the library's root or become hidden files.
- Tests: `TOCTests.parsesTwoSessions` (a full TOC with two sessions), `WAVFileTests.stepsOverOtherChunks` (a `LIST` chunk of odd size before `fmt `), `CueSheetTests.putsAHiddenTrackAndLaterPregapsTogether`, `NameTemplateTests.neverMakesAnEmptyName`.

**Batch 7: docs (items 16d, 16e).** The status table in `Milestones.md`, a "Code review of 0.2" section there with the loose ends to check on hardware, the app section's notes on threads, events, stopping, ATS, and memory; the README's note on plain HTTP; CLAUDE.md's App section and engine conventions.

**Batch 8 (2026-10-21, with Preston): Ctrl-C.** `cdrip rip` and `cdrip repair` turn the first Ctrl-C into `stop.stop()` (`Interrupt` in the CLI): the read under way finishes, the tracks done so far stay, the folder's claim is released, and the command exits with status 130 after saying where the tracks are. A second Ctrl-C ends the process at once. Also the first hardware check of the review's changes: *Reckoning* in the HL-DT-ST and *Dick's Picks Vol. 2* in the MATSHITA, compared with the archive's verified rips (results below).

**Hardware check 1: *Reckoning*, HL-DT-ST BU50N at +6 (2026-10-21).** 15 of 15 tracks accurate; tracks 8, 11, 13, 14, and 15 repaired with CTDB entry 2111910 at shift 0 (5,598 samples; the rip of 2026-10-20 repaired the same tracks with 5,993). Every WAV file is byte for byte the archive's verified rip. About 11 minutes. Nothing in the output changed: the flush, the re-reads, the suspects, and the repair behaved as before.

**Hardware check 2: Ctrl-C, HL-DT-ST BU50N.** A rip of *Reckoning* into a scratch folder, SIGINT sent once track 1 was done: "Stopping after the read under way", then "Stopped. The tracks ripped so far are in ...", exit status 130, 1.1 s after the signal. The folder held `Track 01.wav` and no claim file.

**Hardware check 3: *Dick's Picks Vol. 2*, MATSHITA UJ260AF at +103.** 6 of 6 tracks accurate: tracks 3 and 6 by the secure re-reads (track 3 from the second read's combination, track 6 after one round), tracks 1, 2, 4, and 5 repaired with CTDB entry 127406 at shift −4 (24,141 samples; the rip of 2026-10-20 repaired the same tracks with the same entry and shift, 25,574 samples). Every WAV file is byte for byte the archive's verified rip. About 16 minutes.

All three checks pass: the review's changes to the secure rip, the flush, the threads, and the stop path gave the same audio as before on two damaged discs in two drives.

## For the morning review

Final state: `make format` and `make lint` clean, 216 tests in 48 suites pass. Nothing is staged.

Decisions taken without asking:

- **Read-ahead margin of 128 sectors** next to each range a flush avoids (`AudioReader.readAheadMargin`). The drives measured keep only the latest read, so this is a guess on the safe side; it only limits which free parts a flush may use.
- **A version must come back twice** before a sector is decided (`Versions.isDecided`). Before, a sector with one version was decided at once. This adds one round for a sector that one read could not read and a later one could; it changes nothing for sectors that two reads agree on.
- **"No read confirms the first" is `.suspect`** with no unresolved sectors and `shiftedReads` filled. The summary text says so. A new status case would have touched every switch.
- **The artwork is saved before the report**, so `RipReport.files` can list it: the CLI now prints the cover line before the summary.
- **`RipPool.versions` returns three values** (versions, alternatives, skipped), and `.poolFileSkipped` is a new event in both `DiscRipEvent` and `RipRepairEvent`.
- **`RipEvent` changed shape** (your decision), and `ReadProgress` gained chunk fields; `ProgressLine` prints the same text.
- **`DiscRip.webClient` and `RipRepair.webClient`** are new properties (default `.shared`), used for every request, so tests can give a fake. The CTDB repair data download goes through them too.
- **The drive offset list is fetched only when the drive has no offset from any source.** Before, it was fetched whenever the profile had no listed offset, even with a manual or confirmed one.
- **`NameTemplate.name` never returns an empty name** ("Unknown" instead), and leaves out empty parts.
- **`MP3Error.malformedID3Tag`** is a new case.
- **`blocking(_:)` uses one `@unchecked Sendable` box** for the closure it hands to the GCD thread; the CLI's `RipPrinter` and the tests' event collectors are `@unchecked Sendable` because events come one at a time.

Worth a look on hardware when a disc is in a drive (no code depends on it, but the output should not change): one `cdrip rip` of a clean disc, one of a damaged disc, one `cdrip repair -d` with re-reads, and a `--pool` with a folder that holds a non-WAV "Track 01.wav" to see the new message.

Left as is:

- 16b: the C2 fallback in `TrackRipper` still catches any error from the C2 read. A C2 probe per drive, kept in the profile, needs a drive that refuses C2 to test against.
- 21: ATS exceptions belong in the app's Info.plist, which the project does not have yet (it generates one from build settings).
- 22: memory; noted in Milestones.
- The untracked `App/CDRip.xcodeproj/xcshareddata/xcschemes/CDRip.xcscheme` appeared during the session; nothing here wrote to the Xcode project, so it is probably Xcode's.
