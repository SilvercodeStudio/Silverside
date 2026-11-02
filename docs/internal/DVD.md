# DVD audio extraction

Status: initial CLI implementation, following exploration started 2026-10-31. DVD-Audio extraction to multichannel FLAC is the primary goal. Audio extraction from DVD-Video is a secondary goal. This is not a commitment to a particular Silverside release.

### Current checkpoint — 2026-11-01

The extraction feasibility milestone is complete for the tested MLP titles: unprotected Glen Phillips and CPPM-protected American Beauty/Fragile have full verified stereo and surround FLAC outputs. Presentation-specific track maps and decoder-reset behavior have been exercised. The user's initial listening checks are positive; comparisons between commercial editions do not isolate sample-rate effects.

The initial implementation now lives in the engine and CLI. `dvd info` exposes
program navigation and decoded format; `dvd rip` writes per-track FLAC,
playlists, `dvd-rip.json` and `Rip Report.txt`. The separate Swift helper loads
Homebrew libraries at runtime through opaque public APIs, with no linked DVD
libraries or Homebrew build dependencies. The GUI has not changed.

Supported initially: contiguous one-cell-per-track layouts, constant-format
16/24-bit MLP stereo/5.1, exact 90 kHz timestamp-to-sample conversion, separate
stereo programs and a decoded stereo substream exposed by shared-extent title
references. Unsupported navigation/codecs produce explicit errors. `auto`
prefers surround; `stereo`, `surround`, `both`, or `--title SET:TITLE` select.
Ambiguity requires explicit selection. Short standalone programs require a title.

The helper rechecks the navigation fingerprint before a bounded read. The
engine compares packet timestamps with navigation, decodes self-contained reset
cells independently, and decodes continuous programs before sample-based cuts.
It verifies output rate, bit depth, channel layout, sample count and PCM hashes.
Decoder warnings fail the operation. Programs are promoted from private staging
only after checks pass. Reports distinguish completion, failure and cancellation;
no overwriting or resume. Source read and local decode checks are not independent
database verification or secure reread consensus. No ReplayGain is applied.

Optional DVD-Audio Audio Text can contain album/group/track names, but is not
required. It is not parsed by this milestone; files and tags use numbered
placeholders. See the Audio Text section of the [Sonic authoring manual](https://www.quadraphonic.info/DVD-Audio-SACD-Blu-Ray/manuals/Sonic-DAC_Guide-draft2.pdf).
Metadata lookup, artwork and GUI selection follow later.

### CLI validation and remaining dependency work

- American Beauty stereo: physical MATSHITA extraction, eleven tracks,
  256,547,040 frames, matching the earlier full-program PCM hash below.
- Fragile surround: physical ASUS extraction, ten tracks, 299,062,320 frames,
  matching the earlier full-program PCM hash below.
- American Beauty surround: the new engine/helper read the prior decrypted AOB
  through a plain AUDIO_TS fixture, producing eleven tracks and the matching
  earlier PCM hash. A new physical surround read also completed, but its first
  run caught a cached-file-size bug before decoding; the size/progress checks
  now use fresh filesystem attributes.
- Glen Phillips: the mounted, read-only raw ISO's AUDIO_TS directory completed
  both presentations, eleven tracks each. A short actual decode identifies the
  authored stereo substream; ffprobe's input header alone still reports 5.1.
  The ATS index high bit does not uniquely distinguish these presentations:
  both index bytes have it set. Preserve the raw index byte rather than calling
  it a primary/secondary flag.
- Synthetic tests cover malformed/truncated navigation, ambiguous selection,
  exact six-channel splitting, cancellation, refusal to overwrite, retained
  failure reports, reads across AOB files, and rejection of encrypted folders.
- Both Glen Phillips PCM hashes also match the earlier listening extractions:
  surround `bced84ad906f66b9a4f39ce4a52d1b2a1c4172641fa3fb61c65ce3f68de1325a`,
  authored stereo `2cdfba4d33f7d5b81598b2d90947400264a3711d908d57f90314730a3d7ef6de`;
  each has 236,670,960 frames at 96 kHz.
- `make format`, `make lint`, and `make test` passed (473 engine tests, five
  Darwin tests, two helper tests). `make release` built both executables with
  arm64 and x86_64 slices. `make cli` also builds both and inventories the
  mounted Glen Phillips source successfully.
- An ad-hoc hardened CLI and helper, with the validation exception on the helper
  only, loaded Homebrew libraries and inventoried protected American Beauty.
  Ordinary CLI version output still works with DVD libraries disabled.
- `otool -L` shows only Apple/system dependencies on the helper. Missing DVD
  libraries fail with Homebrew instructions. The helper-only entitlement and
  signing instructions are in `SilversideKit/Sources/silverside-dvd-helper/`.
  Developer ID signing, notarization, clean-machine, Intel runtime and macOS 15
  runtime checks remain release work; an ad-hoc test is not notarization proof.

The installed libdvdread 7.1.1/libdvdcss 1.6.0 fail direct unprotected ISO reads
without an MKB: initialization leaves no CPXM context and a decrypt-mode block
read returns -1. The CLI can read **plain AUDIO_TS directories** without those
APIs. Mount an unprotected ISO read-only and select its directory; automatic
mounting and a general ISO fallback are deferred. Encrypted directories are
rejected and directed to the physical disc. No library source was copied or
patched. FFmpeg also rejects differing channel-group sample rates (see its
[MLP decoder](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/mlpdec.c));
this milestone does not resample those groups.

The upstream license/agreement changes have been pulled. Research utilities
remain in `scripts/dvd/`; they are not bundled or invoked by the product helper.
Further DVD-Audio and DTS-CD titles are incoming and will expand coverage.

## Intended result

Given a supported disc, image, or extracted directory, enumerate its audio presentations, let the user choose the stereo or surround program and tracks, and write correctly tagged lossless files at the source's resolution and with the source's speaker assignments. Preserve the source and report exactly what was read, decoded, transformed, and verified.

Start with a development command, then a reusable engine workflow and CLI, then the app. Establish correct navigation and audio before building selection UI. A decoded surround presentation must never silently become stereo or 44.1 kHz.

### Scope and presentation choices agreed during exploration

- The product goal is usable, high-quality extraction of audio, primarily multichannel FLAC, with track demarcations and correct speaker assignments.
- Discover actual presentations and offer surround, stereo, or both when available. Distinguish an authored MLP stereo substream from a separately stored stereo program and from a software-generated downmix. An authored stereo substream is an encoding/production choice, not something every MLP release necessarily contains; Meridian's encoder exposes an optional stereo-downmix setting ([encoder guide](https://www.meridian-audio.info/public/mlpencoderuser%5B2523%5D.pdf), pages 21 and 43).
- Present selection in the extraction workflow; the exact UI (selector, saved preference, or prompt) is still open. Do not silently synthesize stereo when the user asks for an existing stereo presentation. If both are extracted, keep their files and metadata distinguishable.
- Speaker mapping is essential for faithful audio. Reproducing optional dynamic-range instructions and other DVD playback behavior is not an initial requirement. Keep archival decoding free of optional dynamics processing, and record known unsupported behavior without making it a prerequisite for audio extraction.
- Menus, still frames, and other visual presentation are outside the initial scope. A video export with audio/still imagery is a possible later stretch goal. A video file would not necessarily retain interactive DVD menus; preserving the whole interactive experience is a separate problem.
- A physical 5.1 listening setup is not required to continue development. Validate channel identities/order with synthetic fixtures and inspect channels independently; stereo listening remains useful but cannot establish acoustic surround placement.

## Evidence and starting material

Read-only inspection on 2026-10-31 established:

| Item | Observation |
|---|---|
| Homebrew libdvdcss | Installed 1.6.0; `dvdcpxm.h` and exported `dvdcpxm_init`, `dvdcpxm_read`, `dvdcpxm_readv`, `dvdcpxm_seek`, and `dvdcpxm_close` |
| Homebrew libdvdread | Installed 7.1.1; `DVDOpenAudio`, audio manager/title-set structures, title/track-table readers, and `ifoOpenSAMG` |
| Glen Phillips raw image | `AUDIO_TS` and `VIDEO_TS`; three AOB files; no `DVDAUDIO.MKB` in the directory listing |
| American Beauty raw image | Both domains; four AOB files and `AUDIO_TS/DVDAUDIO.MKB` |
| Both dvdbackup directories | Only `VIDEO_TS`; the reconstructed images therefore omit the DVD-Audio domain |
| Installed ffmpeg | MPEG program-stream demuxer available; `dvdvideo` demuxer absent from the advertised demuxers |

Local inputs (not repository fixtures):

- `/Users/planders/Movies/DVD/Glen Phillips raw.iso`
- `/Users/planders/Movies/DVD/American Beauty DVD-A raw.iso`
- `/Users/planders/Movies/DVD/Glen Phillips/VIDEO_TS`
- `/Users/planders/Movies/DVD/American Beauty/VIDEO_TS`

`dvdbackup -M` in these runs backed up the video domain. `hdiutil makehybrid` repackaged the supplied directory; it could not restore omitted audio files. `dd` copied sectors without decrypting CPPM. Retain the raw images unchanged.

MKB presence is evidence of protection-related material, not proof that every audio packet is encrypted or that a reader has successfully decrypted it. Likewise, absent MKB plus a clean decode is stronger evidence than either fact alone. Earlier discussion reported successful Glen Phillips decoding; this exploration must reproduce and record it before treating it as verified.

## Architecture and licensing decision

Use a separate DVD helper process. Silverside controls selection, progress, cancellation, naming, metadata, encoding policy, and reports. The helper owns DVD-library access and navigation, and emits a documented, versioned inventory plus media data. Keep private library structures out of the protocol.

Upstream commit `81e4dcd` sets the project license to GPLv3-or-later and implements the personal-use acknowledgment. It was fetched, but not yet merged into this working checkout, when the 2026-11-01 full-disc experiments began. The DVD plan follows that upstream decision. The helper process remains useful for optional dependency discovery, cancellation, crash isolation and narrowly scoped code-signing entitlements.

Before distribution, settle whether the helper is independently installed or bundled, and document its source/build instructions, notices and library requirements. The development C clients retain their GPL-2.0-or-later notices. No upstream library implementation has been copied into the repository; preserve that boundary in accordance with the contribution/relicensing policy in upstream `CONTRIBUTING.md` and `CLAUDE.md`. Scratch experiments do not decide final packaging, and user-installed libraries do not replace a distribution review.

### External dependency policy — clarified 2026-11-01

The user installs DVD libraries through Homebrew. Silverside does not bundle, download, install, update or privately copy libdvdread/libdvdcss. Without the required external dependencies, DVD extraction is unavailable and the app explains what to install; CD features remain available. The earlier discussion of an app-managed download was a misunderstanding, not the selected design.

Recommended implementation:

- Ship an original, small DVD helper with Silverside, containing adapter/navigation/protocol code but no CSS/CPPM cipher implementation, decryption keys or statically linked DVD-library code. The main app communicates with it as a separate process and does not load the DVD libraries.
- Have the helper load the user's libdvdread at runtime with `dlopen`/`dlsym`, using explicit Homebrew library paths (Apple silicon `/opt/homebrew`, Intel `/usr/local`; custom locations can be an explicit override). Avoid reliance on a GUI-launched process inheriting a shell PATH, unqualified library search paths or DYLD injection settings. Public headers are build inputs; the shipped helper must have no mandatory link-time dependency on these libraries, so it can report missing/incompatible installations itself.
- Let libdvdread use its external libdvdcss dependency for protected access. The tested Homebrew libdvdread 7.1.1 directly references Homebrew's libdvdcss 1.6.0 dylib; loading libdvdread therefore loads that external dependency too. Do not copy either library into the app to resolve loader failures.
- Validate the required DVD-Audio API symbols, supported ABI/version, process/library architecture, transitive library loading and ffmpeg decoding capabilities. A file's presence alone does not establish availability. Use the helper's structured capability result to distinguish absent, outdated/incompatible and loading-blocked dependencies from disc authentication/read errors.
- For the Developer ID helper, test `com.apple.security.cs.disable-library-validation` on the helper alone. The installed Homebrew libraries are ad-hoc signed and have no Team ID, so they do not meet the ordinary same-team library-validation rule. Keep the main app's validation enabled, and do not add privileged execution or broad DYLD exceptions. Verify signed/notarized loading and a protected read on a supported Mac before declaring distribution readiness. See [Apple's entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation).
- Gate DVD extraction on usable dependencies. Offer the install command and a recheck action; do not execute Homebrew automatically. Continue using external ffmpeg for the planned MLP decoding path. Missing DVD support must not prevent the app or helper capability command from starting.

Immediate packaging proof: build this runtime-loading helper, inspect its Mach-O dependencies and app bundle to confirm no DVD libraries are shipped, and test missing libraries, working Homebrew libraries, version/architecture mismatch and signed-helper loading. Then carry the proven inventory/extraction behavior into its versioned protocol. The existing scratch C clients link directly to local libdvdread and establish extraction feasibility; they are not yet this optional-loading production helper.

### Helper interface

Proposed operations, not existing commands:

- `capabilities`: protocol version, architectures, library versions and audio/protection capabilities.
- `inventory SOURCE`: JSON describing source domains, navigation, programs, tracks, extents, and known/unknown stream attributes.
- `extract SOURCE --domain audio --title-set N --title N ...`: selected media to a file or stdout; structured progress and diagnostics on a separate channel.

Use numeric identifiers scoped to domain/title set/title. Retain raw identifiers and uncertain fields rather than guessing labels. Distinguish unsupported, protected, authentication unavailable, malformed navigation, source read failure, and decoder failure. Never report an empty inventory as success after parsing failed. No shell interpolation of paths. Handle early pipe closure, child termination, and cancellation without leaving apparently complete output.

## Phase 1: image inventory

### Proposed end-user Homebrew requirements

For the DVD-Audio helper design, the current minimal install command is:

```sh
brew install ffmpeg libdvdread
```

Homebrew's `libdvdread` 7.1.1 depends on `libdvdcss` 1.6.0, so users do not need a separate install command for the latter. The helper uses libdvdread for file/navigation access and libdvdcss for protected access; ffmpeg handles audio decoding and can encode FLAC. No `dvdbackup`, standalone `flac` tool, Python, or compiler is required for the proposed GUI workflow with a prebuilt helper. CPPM hardware decryption has passed on both protected test titles; packaging and clean-machine validation remain outstanding.

If the DVD-Video implementation uses libdvdnav, the combined install command can become `brew install ffmpeg libdvdnav`: libdvdnav brings in libdvdread, which brings in libdvdcss. Installing those libraries does not retrofit the `dvdvideo` demuxer into an existing ffmpeg binary; navigation would need to live in our helper or use a suitably built ffmpeg. Sources: Homebrew [libdvdread](https://formulae.brew.sh/formula/libdvdread), [libdvdnav](https://formulae.brew.sh/formula/libdvdnav).

Existing Silverside distinction: the optional ffmpeg executable is used for DTS-CD decoding; the HDCD decoder is vendored and does not require the user to install ffmpeg. LAME remains the MP3 encoder.

### Inventory procedure

Start with installed libdvdread's explicit DVD-Audio mode. Determine whether its parsers provide reliable navigation before implementing an independent parser.

Record:

- Image byte length, filesystem inventory, both domain presences, MKB presence, and AOB part sizes.
- Audio manager title/group references and their target title sets/titles.
- Audio title-set records, primary/secondary entries, programs/tracks and cells.
- Raw PTS start/duration values, derived times, and inclusive AOB-relative sector ranges. Preserve the distinction between programs and cells; there need not be one cell per track.
- Audio attribute bytes and any interpretation supported by the API; distinguish navigation declarations from stream-probed codec, rate, precision, and layout.
- Video-domain title/chapter/stream inventory as a secondary operation, using explicit video-domain inputs if hybrid autodetection chooses audio.
- Tool/library versions, warnings, and failed tables.

Check bounds against actual file sizes, cell ordering, track-to-cell references, program-duration sums, and duplicate/overlapping title references. Do not assume PTS starts form a title-relative timeline, or that every title-table row is a separate album presentation. Sparse/zero audio attributes must remain unknown until stream probing resolves them.

Use bounded reads and timeouts. Inventory is read-only: no mounting requirement, source writes, full AOB extraction, device authentication, or library installation. Store reproducible scratch commands/results outside the source tree, then summarize findings here. Do not commit copyrighted audio or full disc images.

Exit criterion: both raw images yield an explainable navigation inventory, with uncertainties and parser limitations identified. A partial result must identify the missing pieces.

## Phase 2: unprotected DVD-Audio to multichannel FLAC

Use Glen Phillips first. Read the selected program's logical AOB extents across file boundaries, demultiplex its audio, and decode through the external ffmpeg. Evaluate MLP and DVD-Audio LPCM separately; successful MLP decoding does not prove support for every LPCM packing or channel-group arrangement.

Initially decode a complete selected program continuously. Use navigation, packet timestamps, and decoded sample positions to establish track cuts. Allow decoder preroll at seek points. AOB boundaries are storage boundaries, not tracks; rounded seconds and byte concatenation alone do not establish correct cuts. Account for discontinuities, repeated navigation references, codec changes, and title boundaries explicitly.

Preserve sample rate, valid precision, channel count, speaker identities/order, and original codec. Do not infer layout from channel count alone. Treat mixed channel-group rates/precision as a case needing explicit investigation; document any required conversion instead of silently claiming bit-perfect preservation.

FLAC is the first output. Decode it back and compare canonical PCM, sample count, rate, and channel layout against the pre-encode PCM. Compare all per-track PCM concatenated against the continuous selected-program decode. This detects split errors independently of encoder round-trip checks. Reject unsupported layouts instead of silently remapping or downmixing them. Preview downmix, if offered, is separate from archival output.

Exit criterion: a full program with correct track count/durations, no missing or repeated samples at joins, preserved surround channels, and documented round-trip verification. Add synthetic channel-identification and boundary fixtures before promoting the extraction code into the engine.

## Phase 3: CPPM proof on hardware

American Beauty is the initial protected-disc candidate. Ask for the disc/drive when this phase begins and identify the current device; do not assume an old `diskN` remains valid.

First exercise libdvdread's DVD-Audio read path to determine whether it handles CPPM initialization and decrypted reads using the installed libdvdcss. Only build a lower-level `dvdcpxm_*` adapter if necessary. Verify drive authentication and album-ID access on macOS rather than inferring platform support from exported symbols.

Start with one small audio segment and confirm decoder output, then repeat reads and extend to a complete program. Record initialization status, read errors, decoder diagnostics, and repeat-read hashes. Do not interpret a successful open as successful decryption, or decode failure alone as proof of encryption.

A plain image may lack drive-provided information needed for CPPM initialization. Image-only protected extraction is not a promised capability. Keep separate states for unprotected images, already-decrypted sources, protected images requiring additional access, and physical protected discs. Avoid logging authentication secrets. Preserve original images; decrypted working data goes elsewhere.

Exit criterion: repeatable protected-disc extraction on at least one drive, with clear failure behavior on unavailable authentication and missing dependencies. Then check another protected title and, where practical, another drive.

### Follow-on experiment: decrypted DVD image — 2026-11-01

Explore an optional DVD counterpart to CD image/CUE output: a self-contained, decrypted DVD filesystem image retaining the original compressed audio and navigation. This is distinct from decoded FLAC export and from reauthoring a new disc from FLAC. It is not yet an implemented or hardware-validated output mode. Burning support inside Silverside is not required for this experiment.

The CPPM proof establishes that the installed libraries can produce clear sectors while the original disc is available. Album ID alone is not the whole decryption input: the library also processes the MKB using its device-key material and the per-pack information. Prefer the working library path rather than implementing cryptography or exporting secrets. Once a complete decrypted image is produced, reopening it should require neither the original disc nor an authenticated context.

Proposed experiment:

1. Finish full protected-program extraction and verification first (next milestone below). Preserve original MLP/LPCM packets alongside decoded FLAC where useful; decoding and re-encoding MLP is unnecessary for an image copy.
2. Inventory every file and its filesystem extents, including audio managers, title sets, still images, menus, backups, and any DVD-Video domain. Test copying the original image to a new output and replacing encrypted file sectors with equal-length decrypted sectors from the physical-disc read path. This could retain existing layout/pointers and reuse the raw ISO, without requiring an image-plus-external-album-ID API. It remains a hypothesis until all extents and read domains are verified; never patch the source image.
3. Handle protection by domain, not filename extension alone. DVD-Audio menu/still VOBs can use CPPM; VIDEO_TS uses CSS. The installed library series explicitly supports this distinction ([VideoLAN release notes](https://jbkempf.com/blog/2026/DVD_VR_edition/)). A decrypted AOB alone is not proof of a fully decrypted hybrid image.
4. Audit scrambling flags, copy-control metadata, MKB/backup handling and filesystem metadata for a self-consistent unprotected output. Do not assume deleting the MKB is sufficient, or blindly remove it before verifying how readers identify protection. Record every changed extent and metadata transformation. The inspected libdvdcss 1.6.0 CPPM path clears packet scrambling flags and, by default, resets packet CCI; that behavior is not a complete image-authoring contract.
5. If rebuilding the filesystem rather than retaining its layout, use DVD-Audio-aware ordering and update navigation that contains absolute sector references, notably AUDIO_PP.IFO. Validate the existing Glen Phillips SAMG offset discrepancy rather than carrying it into a generic relocation algorithm. The [DVD-Audio Tools filesystem notes](https://dvd-audio.sourceforge.io/spec/udf.shtml) describe ordering and pointer requirements; generic UDF packaging alone is not our compatibility proof.
6. Reopen in a fresh process with no physical-disc authentication or decryption dependency. Exercise all presentations and available navigation; compare decoded PCM against direct-disc extraction, and hash unchanged regions. Only then test an appropriately sized recordable DVD with read-back verification and a DVD-Audio-capable hardware player. Do not equate software playback, successful burning, and standalone-player compatibility.

Compatibility limits: the image must fit the target medium (a dual-layer original may need a dual-layer blank), and a normal DVD-Video player does not acquire DVD-Audio support by burning the image. Embedded audio watermarks are separate from packet encryption and survive lossless copying; player enforcement may affect playback of an otherwise decrypted copy. Treat this as a hardware compatibility question, not a reason to alter archival PCM. The [4C protection architecture](https://www.4centity.com/documents/content-protection-system-architecture) describes watermark-based playback checks. We have not established whether any current test title has such a watermark.

### Next execution milestone — 2026-11-01

The full-album extraction and verification in steps 1–3 completed later on 2026-11-01; see the results at the end of this document. Helper protocol and decrypted-image work remain next.

1. Extract American Beauty's complete surround and stereo programs through the proven physical-disc path, with bounded reads, progress and cancellation. Identify the currently mounted device before accessing it; previous disk numbers are not stable identifiers.
2. Resolve each presentation's track/cell timeline, including timestamp discontinuities and the short terminal program. Produce per-track FLAC and verify source-to-FLAC PCM equality plus equality between joined tracks and each continuous presentation. Record any unresolved editorial track boundary separately from sample-continuity verification.
3. Repeat on Fragile, whose stereo/surround boundaries differ, and assess ASUS reliability or use another available drive. Use these two protected titles plus unprotected Glen Phillips to establish a reusable presentation/navigation model.
4. Build a stable helper inventory/extraction protocol from those results. Pursue the decrypted-image experiment as a separate preservation output, and refine Classic Records' DVD-Video chapter/audio alignment afterward. Sample-rate listening experiments remain independent personal research.

## Phase 4: Silverside engine and CLI

Introduce a DVD source/navigation model alongside the CD model. CD TOCs, 75 sectors per second, 588 stereo frames per sector, read offsets, AccurateRip, CTDB, and CD CUE conventions do not apply to DVD audio.

Reuse naming, metadata editing, cover handling, tagging, history, progress, and atomic output where their assumptions fit. Audit `AudioEncoder`, `SurroundPCM`, `SurroundLayout`, `DiscEncoder`, reports, and playback before reuse. In particular, current `SurroundPCM` stores channel mask and precision but no sample rate: it is not yet a general DVD PCM representation. Prefer bounded streaming to holding an entire high-resolution multichannel album in memory. Consider RF64/WAVE64/CAF or streamed raw PCM with explicit format metadata for intermediates beyond WAV's usual size limits.

Persist a versioned DVD manifest with source identity, domain, group/title/track selection, extents, original codec, PCM format, tool versions, protection/read/decode outcomes, transformations, and output hashes. Keep source-stream preservation and decoded FLAC as distinct artifacts. Avoid collisions between stereo and surround editions. Resume only when source identity and selection match.

Metadata must support manual naming and release selection; a DVD does not have a CD AccurateRip/MusicBrainz TOC identity. Reuse the existing rate-limited metadata client rather than ad-hoc service calls. Keep chapter labels and editorial track names distinguishable.

Report verification precisely: source read success, repeated-read agreement if performed, decoder integrity, and lossless output round-trip. Neither a matching local hash nor an MLP checksum is an AccurateRip/CTDB consensus result. A lossy source decoded to FLAC remains a lossy-origin source.

Exit criterion: a CLI workflow can inventory, select, extract, tag, verify, cancel, resume, and report without disturbing existing CD behavior.

## Phase 5: DVD-Video audio

Add title, program-chain/cell, chapter, angle where applicable, and audio-stream selection. Support PCM, AC-3, and DTS as separate source codecs, preserving provenance and language. Resolve playback order through navigation; blindly concatenating all VOB files can include menus, alternate paths, or duplicated material.

Investigate libdvdread/libdvdnav in the helper, or an ffmpeg build with the documented `dvdvideo` demuxer. The installed ffmpeg currently lacks that demuxer, so capability detection must check it explicitly. Do not make an extra dependency mandatory for DVD-Audio unless that path actually needs it.

Maintain separate CSS and CPPM capability/error paths on hybrid discs. Offer audio-domain selection explicitly. DVD-Video tracks may be chapter-based rather than an album's editorial track list.

Exit criterion: correct selected-stream extraction and chapter cuts on a known DVD-Video title, including a multichannel example and a hybrid title.

## Phase 6: app and distribution

The app shows each available presentation with verified codec/rate/precision/layout and track list. Prefer the user's multichannel FLAC workflow, while allowing stereo selection explicitly. Never select an arbitrary first stream when several presentations exist. Show dependency availability and actionable errors. Ensure optical-drive access is coordinated with existing CD jobs and previews.

Developer ID distribution remains the target, not the Mac App Store. A bundled hardened helper loading Homebrew libraries may need `com.apple.security.cs.disable-library-validation`; scope it to that executable and keep the main app's validation enabled. This exception is compatible with notarization, but test a real signed/notarized build on a clean machine and macOS 15. It neither grants drive privileges nor provides process sandboxing. Check architectures, dependency discovery, transitive libraries, launch environment, and termination behavior. Do not broadly enable DYLD injection exceptions.

Upstream commit `81e4dcd` implements the personal-use acknowledgment in the app and CLI, using shared `Settings.agreedToPersonalUse` and `silverside --accept-disclaimer` for noninteractive acceptance. Future DVD integration should use the existing policy and wording. No separate acknowledgment implementation is needed for these inventory experiments.

## Validation matrix

| Area | Required cases |
|---|---|
| Sources | Unprotected image/directory, protected physical disc, protected image without authentication, audio-only and hybrid layouts |
| Audio | MLP and LPCM; stereo and multichannel; 44.1/48 kHz families and high rates; 16/20/24-bit where available; unusual speaker assignments |
| Navigation | Multiple groups/titles, alternate presentations, more cells than tracks, AOB boundary inside a track, discontinuities and shared extents |
| Integrity | Continuous decode versus track joins, channel-ID fixtures, FLAC PCM round-trip, repeat reads, malformed/truncated tables and sectors |
| Workflow | Cancellation, child failure, full output disk, existing destination, resume mismatch, source ejection, missing libraries/ffmpeg |
| Distribution | Native architectures, Homebrew paths, signed helper, notarization, clean machine, supported macOS versions |

Use small synthetic fixtures for committed tests. Real-disc observations and local artifacts supplement those tests without committing copyrighted recordings. Run repository formatting, lint, and tests when production code changes; documentation and external scratch inventory do not require rebuilding the app.

## Personal research: sample-rate conversion and listening

Planned at the user's request; no experiments completed yet. This is for personal curiosity, not a commitment to add sample-rate conversion to Silverside. Preserve the original extracted PCM as the archival reference and generate separate experimental copies.

- Start with a verified 96 kHz/24-bit authored stereo extraction. Compare the original with 48 kHz/24-bit and 44.1 kHz/24-bit conversions of the same source. Keep the mix, channel layout, bit depth and gain constant; do not compare different commercial masters or authored stereo against a surround downmix.
- For controlled listening, also upsample each converted copy back to 96 kHz so all candidates use the same playback rate. This tests the conversion round trip and bandwidth reduction while avoiding device rate-switching cues. Keep native-rate playback as a separate experiment that includes the player's and DAC's behavior.
- Use randomized, blind ABX trials with aligned excerpts, matched levels, and identical playback processing. Disable ReplayGain, normalization, EQ and spatial effects for the baseline. Choose excerpts and trial counts in advance and record all results, including unsuccessful discrimination; keep preference judgments separate from identification accuracy.
- Check resampling peaks and avoid clipping. If attenuation is needed, apply the same fixed attenuation to the reference and all derived candidates before conversion. Record converter/version, filter settings, quantization/dither settings, source hash, durations, alignment, peak measurements, and playback hardware/software. A waveform difference alone does not establish audibility.
- Later vary converter/filter settings one at a time, repeat with multichannel material using consistent speaker routing, and investigate 24-to-16-bit conversion with appropriate dither as a separate question. Keep scripts and experiment notes under `scripts/dvd/` and this document; keep generated audio outside the repository.

The aim is to find out what is distinguishable on the user's playback setup, without assuming either that higher rates sound better or that every conversion must be inaudible. This research does not change the extraction plan's default of preserving source rate and precision.

## References

- [VideoLAN DVD-Audio implementation report](https://xhcfs.github.io/GSoC-2025-Videolan-DVD-Audio/GSoC-final-report.pdf): DVD-Audio support across libdvdcss/libdvdread/VLC and known implementation challenges.
- Installed headers: `/opt/homebrew/include/dvdcss/dvdcpxm.h`, `/opt/homebrew/include/dvdread/dvd_reader.h`, `ifo_read.h`, and `ifo_types.h`. These describe the actual local API used by the first prototype.
- [FFmpeg DVD-Video demuxer](https://ffmpeg.org/ffmpeg-formats.html#dvdvideo).
- [Apple notarization guidance](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) and [library-validation entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation).
- [GNU license FAQ](https://www.gnu.org/licenses/gpl-faq.en.html).
- [U.S. Copyright Office section 1201 overview](https://www.copyright.gov/policy/1201/).

## Inventory results — 2026-10-31

The first DVD-Audio inventory completed successfully for both raw images using libdvdread 7.1.1. Both contain one audio title set, with two ATS title-table rows. Raw ATS bytes independently agree with every parsed program start/duration and cell extent. All program-duration sums equal their title durations; all cells are within the concatenated AOB file sizes. No physical drive or CPPM initialization was tested.

### Glen Phillips

- Image size: 4,515,299,328 bytes.
- AOB parts: 1,073,709,056; 1,073,709,056; 19,793,920 bytes. Total: 1,058,209 sectors of 2,048 bytes.
- Two audio-manager references/groups and two primary ATS rows (`0x81`, `0x82`), each with 11 programs and 11 cells, lasting **41:05.3225**.
- Both ATS rows reference exactly the same AOB-relative cell ranges, from sector 0 through 1,058,208 inclusive. They are not two separately stored albums. How the two references select a presentation/downmix remains to be established; do not collapse them blindly or label one stereo without evidence.
- A 4 MiB sample at the filesystem's first AOB extent probes as **MLP, 96,000 Hz, 24 valid bits, six channels, 5.1**, stream ID `0xa1`. ffprobe exits successfully with no diagnostic output. This is stream-probe evidence for the beginning only, not a full-program decode or channel-order verification.
- The ATS attribute row agrees: encoding `01`, precision `22`, rate `11`, channel-assignment byte `14`. Other attribute rows are zero.
- ATS track starts form a continuous PTS timeline beginning at 109. Cells are contiguous across the program.
- The simple audio manager (SAMG) repeats 11 chapters for each of two groups, but **every reported sector range is 38 sectors earlier than the corresponding filesystem/ATSI-derived absolute range**. The first SAMG start is 6,234; ISO9660 places the first AOB at 6,272. The cause is unresolved. Prefer validated file-relative ATS cell ranges for the next extraction experiment, rather than trusting SAMG absolute locations.
- libdvdread logs missing MKB and two specification-version assertions. Raw bytes confirm the audio manager declares `0x0011` and the still-video manager `0x0000`, where this library expects `0x0012`. These warnings did not prevent parsing; preserve them in diagnostics rather than silently treating the source as fully validated.

### American Beauty

- Image size: 4,587,472,896 bytes. `DVDAUDIO.MKB` is present; audio decryption remains untested.
- AOB parts: 1,073,709,056 bytes each for parts 1–3; 806,901,760 bytes for part 4. Total: 1,966,811 sectors.
- One audio-manager audio reference, but **two ATS rows**: primary `0x81` and secondary `0x01`. Each contains 11 programs and 11 cells, lasting **44:32.365**.
- Primary row: AOB-relative sectors 0–1,441,191. Secondary row: 1,441,192–1,966,810. Together they cover all AOB sectors; each row is internally contiguous.
- Attribute row 1 is the same MLP/24-bit/96 kHz/channel-assignment declaration as Glen Phillips (`01 22 11 14`). Row 2 declares MLP, 24-bit/96 kHz with channel assignment `01` (stereo according to the installed header). These suggest surround and stereo alternatives, but associating each with decoded stream properties remains a protected-disc task. No protected audio was decoded in this inventory.
- **Every program starts at PTS 660**, so timestamp alone is not a unique program position. Track extraction needs the navigation context and timestamp discontinuity handling.
- The 11th program is only **one second** long in both rows. Its role is unknown; do not silently drop it or claim it is an album song.
- SAMG has just 11 chapters: the first ten match the secondary ATS row's first ten cells, but the last matches the primary row's one-second cell. Thus SAMG alone would omit the main surround region and follow a different last-cell selection. Full ATS navigation is required for the user's surround-first workflow.
- No libdvdread diagnostics were emitted by the audio inventory. Both manager specification versions checked are `0x0012`.

### Program durations from ATS navigation

Both rows on each disc have the same durations. These are navigation values divided by the 90,000 Hz PTS clock, rounded below; sample-accurate cuts are not yet established.

| Program | Glen Phillips (seconds) | American Beauty (seconds) |
|---|---:|---:|
| 1 | 204.240000 | 320.166667 |
| 2 | 182.915833 | 207.633333 |
| 3 | 194.464167 | 248.566667 |
| 4 | 197.176667 | 143.433333 |
| 5 | 284.770000 | 412.726667 |
| 6 | 200.400000 | 253.840000 |
| 7 | 178.480000 | 238.300000 |
| 8 | 247.462500 | 208.360000 |
| 9 | 253.054167 | 312.071667 |
| 10 | 308.626667 | 326.266667 |
| 11 | 213.732500 | 1.000000 |

### Secondary DVD-Video inventory

Using the existing dvdbackup directories, libdvdread enumerated 26 video titles across six title sets for Glen Phillips, and three titles across three title sets for American Beauty. It also enumerated title/chapter-to-program-chain mappings. This confirms that “marketed as DVD-Audio” does not imply an absent video domain on this American Beauty pressing.

The video title-set attributes declare AC-3 (`audio_format=0`) with six channels for Glen Phillips sets 1, 2, and 4, and two channels for sets 3, 5, and 6. American Beauty declares six channels in sets 1 and 2, and two in set 3. These are IFO declarations, not stream-probe or playback evidence; six channels alone does not verify speaker assignment.

Both video-directory opens logged three `Can't seek to block 2688695244` messages and `Couldn't find device name`, despite returning parsed title and stream tables. Their cause needs investigation before relying on this directory-open path for extraction. Full title playback order and chapter boundaries have not been validated. Glen Phillips' audio-manager video reference reports 16 chapters for title set 4 while the video manager reports 13; do not conflate these domains' navigation references.

### Reproduction and artifacts

Utility sources are now preserved in `scripts/dvd/`, with build/run instructions in its README. Generated reports, binaries, and media remain under `/private/tmp/silverside-dvd-inventory` (temporary, not versioned):

- `inventory.c`: explicitly GPL-2.0-or-later scratch client of public libdvdread APIs. Opens an image through read-only `FILE` stream callbacks and `DVDOpenStreamAudio`, without opening a drive. Emits the raw audio navigation inventory.
- `video.c`: separate video-directory inventory client with the same license designation.
- `scripts/dvd/inspect_images.py` (original scratch name `inspect.py`): bounded ISO9660 directory traversal, AOB extent checks, duration checks, SAMG/ATSI comparisons, JSON reports, and the bounded Glen Phillips ffprobe sample. This is an experiment tailored to these single-title-set images, not a production filesystem parser. The saved utility accepts image/output paths and keeps generated media outside the repository.
- `glen-phillips.txt`, `american-beauty.txt`, corresponding `.stderr` and `.json` files; `*-video.txt` and `*-video.stderr`; `glen-streams.json` and `.stderr`.
- `glen-first-4MiB.aob`: local copyrighted media sample; never commit or distribute it.

Build the audio probe with:

```sh
clang -Wall -Wextra -Werror -I/opt/homebrew/include \
  scripts/dvd/inventory.c \
  -L/opt/homebrew/lib -ldvdread \
  -o /private/tmp/silverside-dvd-inventory/inventory

/private/tmp/silverside-dvd-inventory/inventory \
  '/Users/planders/Movies/DVD/Glen Phillips raw.iso'
/private/tmp/silverside-dvd-inventory/inventory \
  '/Users/planders/Movies/DVD/American Beauty DVD-A raw.iso'
```

Both C probes compiled with warnings treated as errors and both audio inventory runs returned zero. The independent raw-byte check read each ATS table at its declared sector offset, then compared the program timestamps/durations and cell extents with the C report. This does not establish complete parser correctness, decryption, or decoded-audio integrity.

Next: reproduce a continuous Glen Phillips decode and investigate how its shared-sector title references select presentations. Establish sample-accurate track cuts from the full ATS navigation, then begin the separate American Beauty CPPM hardware experiment. The SAMG findings make a simplified-manager-only extraction design unsuitable.

### Short MLP/FLAC round-trip proof

The saved `scripts/dvd/verify_sample.py` successfully decoded three seconds of Glen Phillips' MLP to FLAC and decoded the FLAC back. ffprobe confirmed 96,000 Hz, 24 valid bits, six channels and layout `5.1`. All 288,000 frames (5,184,000 bytes of packed signed 24-bit PCM) exactly matched the direct MLP decode. PCM SHA-256: `524d93c46b58209f7698da2257dd00605e1da7ab06898243bd14a08aab35f252`.

The first attempt retained source timestamps and ffmpeg logged non-monotonic muxer timestamps. Rebuilding timestamps from decoded sample count (`asetpts=N/SR/TB`) made the continuous-sample check pass without diagnostics or sample changes. This is evidence for codec/resolution compatibility, not a validated policy for discontinuous DVD programs. Full-program decoding, presentation selection, track boundaries, and physical speaker assignment remain to be verified.

FLAC can losslessly store integer PCM at this combined rate/precision/channel count; no resampling, precision reduction, or stereo downmix is necessary. MLP and FLAC are different lossless representations of the decoded PCM, not formats to wrap one inside the other. References: [FFmpeg codec support](https://www.ffmpeg.org/general.html), [FLAC specification](https://www.rfc-editor.org/rfc/rfc9639.html).

## Presentation metadata and format limits

MLP can encode an authored stereo presentation using lossless matrixing alongside the surround presentation. This is more than a generic player downmix preference. Exporting each presentation to its own lossless file is the practical way to retain both listening choices. Neither a 5.1 FLAC nor a 5.1 ALAC automatically preserves a selectable MLP stereo substream. See the original authors' [MLP system paper](https://aes.org/publications/elibrary/elibrary-page/?id=8082).

Meridian's encoder documentation describes per-channel downmix coefficients, including phase, plus optional dynamic-range data, time codes, text, and ownership fields. DVD-Audio channel groups may have different rates and precision. These need separate preservation/conversion policies; generic tags do not guarantee equivalent player behavior. Source: [Meridian encoder guide](https://www.meridian-audio.info/public/mlpencoderuser%5B2523%5D.pdf).

An important decoder limitation: current [FFmpeg MLP source](https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/mlpdec.c) explicitly rejects channel groups with differing sample rates. Do not advertise universal MLP/DVD-Audio support based on the equal-rate Glen Phillips success. Its `-downmix stereo` decoder option can select an encoded stereo substream, distinct from an output `-ac 2` conversion. A local short debug probe on Glen Phillips confirmed extraction of the two-channel downmix from substream 0. This makes authored stereo extraction worth a separate follow-up; it does not yet prove how the two DVD title references control playback.

Both FLAC and ALAC can preserve 96 kHz/24-bit/5.1 integer samples. FLAC defines speaker assignments and a channel-mask metadata convention; ALAC has its own channel ordering. Correct translation between orders is essential, and a codec's capability is not a promise that every player/output device supports it. Apple documents ALAC at 16/20/24/32 bits, one to eight channels, and arbitrary integer rates through 384 kHz. Sources: [FLAC RFC](https://www.rfc-editor.org/rfc/rfc9639.html), [Apple ALAC README](https://github.com/macosforge/alac/blob/master/ReadMe.txt).

Disc menus, still pictures, title selection, and program navigation belong to the DVD presentation and need not accompany a decoded audio file. Preserve the source image/navigation manifest for those features. Avoid applying dynamic-range processing to archival PCM by default; distinguish authored stereo, separately mastered stereo, and a generic software downmix.

### Track demarcation policy

Prefer individually tagged lossless tracks plus a manifest with exact sample offsets. Decode continuously where the source is continuous, split at validated boundaries, and prove that concatenated track PCM matches the continuous decode. This establishes no lost/duplicated samples; it does not by itself prove the intended musical start of each track. Validate that separately against navigation, packet timestamps and listening.

For a single-file album, FLAC's native non-CD CUESHEET block supports sample-based track/index offsets. Do not force high-resolution boundaries into CD's 75-frame-per-second timing grid. Player support for embedded cues/chapters varies, so keep the manifest and separate-track option. ALAC-in-MP4 chapter navigation is a container/player concern, not a feature of the ALAC codec itself. Source: [FLAC CUESHEET specification](https://www.rfc-editor.org/rfc/rfc9639.html#section-8.7).

## Full Glen Phillips listening extraction — 2026-10-31

`scripts/dvd/listen_glen.py` produced a continuous FLAC, 11 numbered/tagged track FLACs, an M3U8 playlist, and a JSON sample-offset report in `/private/tmp/Silverside DVD Listening - Glen Phillips`. The directory is temporary and contains local media, not repository fixtures.

Verified:

- Continuous output: 96,000 Hz, 24 valid bits, six channels, `5.1`; 236,670,960 frames, or 41:05.3225. This exactly matches the ATS duration sum.
- Each track has the format and integer frame count predicted by its ATS duration. No rounding was needed to convert these PTS durations to sample counts.
- Decoding the continuous FLAC and the concatenated 11 track FLACs gives identical packed 24-bit PCM: 4,260,077,280 bytes; SHA-256 `bced84ad906f66b9a4f39ce4a52d1b2a1c4172641fa3fb61c65ce3f68de1325a`.
- Extraction, splitting and verification emitted no error-level ffmpeg diagnostics. Timestamps were rebuilt from decoded sample count for this continuous program; audio was not resampled or downmixed.

These checks validate the listening files' format, lengths, and lossless partitioning. They do not constitute an independent full-program MLP-versus-FLAC PCM comparison, acoustic speaker-ID verification, or proof that each cut is the intended musical boundary. Track names remain placeholders. Listen at track joins and compare against the disc's presentation before treating these boundaries as production-validated. American Beauty's protected audio has not been extracted.

User listening check: the user copied the files out of the temporary directory and reported excellent fidelity through a stereo setup on the Mac, with no unusual song transitions. This release does not provide a continuous/gapless concert test, so gapless transition behavior remains to be exercised with suitable material. The user has an LG soundbar with virtual surround (no separate surround speakers) and a stored 5.1 receiver that could be set up later. These can support future playback checks; there is no currently assembled discrete 5.1 speaker setup. This is positive listening evidence for the extracted audio through that playback path, not validation of physical 5.1 speaker routing or of the authored MLP stereo substream (the supplied files were surround).

## Authored stereo experiment — 2026-10-31

The extraction utility now supports `--presentation stereo` using the MLP decoder's `-downmix stereo` input option. This selects the encoded stereo substream previously confirmed in debug output; it does not apply an output `-ac 2` mix to surround PCM. The default remains surround. This is a concrete test of exporting either presentation independently; generic disc presentation enumeration and the exact relationship to the two ATS title references remain unresolved.

Outputs are in `/private/tmp/Silverside DVD Listening - Glen Phillips Authored Stereo`: continuous `Glen Phillips - stereo.flac`, 11 numbered tracks, playlist and completion report. The format is 96 kHz/24-bit stereo, with the same 236,670,960 frames (41:05.3225) and navigation-based track positions as surround. The updated utility computes a SHA-256 of packed 24-bit PCM directly from the source decode, then compares the continuous FLAC and joined track PCM with it. It also checks every track's declared sample count, channel count and precision. Only a completed `listening-report.json` establishes that all these checks passed; files may exist before verification completes.

Completed successfully: source PCM, continuous FLAC PCM and joined track PCM all have SHA-256 `2cdfba4d33f7d5b81598b2d90947400264a3711d908d57f90314730a3d7ef6de` over 1,420,025,760 bytes. All 11 per-track format/length checks passed, and the warning-level extraction/split/verification logs are empty. This verifies lossless encoding and partitioning for the authored stereo, using the same ffmpeg decoder for the comparisons; it is not an independent decoder implementation check.

### Authored stereo versus generic downmix

`scripts/dvd/compare_stereo.py` compared program seconds 60–90 with ffmpeg 9.0.2. It saved two 96 kHz/24-bit stereo FLAC clips and `comparison.json` in `/private/tmp/Silverside DVD Stereo Comparison`.

The authored stereo and ffmpeg's default `-ac 2` downmix of the surround FLAC are not sample-identical. Even after independently fitting the best scalar gain for left and right, residual RMS differences are about 14.0% and 13.3% of the authored channel's RMS, respectively. Correlations are approximately 0.9902 and 0.9911. This demonstrates differences beyond simple per-channel gain in this excerpt; it is not a quality ranking, a complete characterization of the mixing coefficients, or evidence that any specific Mac player uses ffmpeg's downmix.

Product implication: retain separate labels for authored stereo and software downmix. A future “both” extraction should preserve the authored stereo when present rather than substitute a generic rendering. A decoder substream request and output channel conversion are different operations.

### Listening levels and ReplayGain

The user listened to authored stereo and reported that it sounded different and quieter than the surround file rendered through VLC on the same stereo setup. No ReplayGain tags or gain processing were applied to these listening files; the authored stereo FLAC's tags were inspected and contain only artist/title/encoder. Do not interpret the observed playback difference as a decoding fidelity failure.

Production extraction should analyze each presentation independently and write track/album ReplayGain and peak tags without modifying archival samples. Treat stereo and surround as separate album presentations so their album gain preserves each presentation's internal track balance. Existing `ReplayGain.analyze` supports surround channel weighting and a sample-rate argument; the DVD integration must pass the real rate (96 kHz here), not its default 44.1 kHz. Equal loudness before a player's surround-to-stereo rendering does not guarantee equal perceived loudness afterwards; a player's downmix, gain and clipping behavior matter. The user's usual player is Petrichor, whose ReplayGain behavior they report works well. Reproducing particular player behavior is not assumed.

## American Beauty raw-image protection check — 2026-10-31

Do not discard the raw ISO. It preserves AOB data, MKB and navigation and is already useful for parsing and reproducible tests. “Needs the physical disc for CPPM setup” is not equivalent to “the ISO cannot be useful for extraction.” An eventual image-data-plus-drive-authentication design may avoid rereading all audio from the optical disc, but is not implemented or validated.

`scripts/dvd/probe_raw_audio.py` sampled 4 MiB from the start of each ATS audio region. In each sample, 2,047 private-stream PES headers had scrambling-control value 2 and one had value 0. Both direct ffmpeg decode attempts failed with MLP major-sync checksum errors (and the stereo sample also reported a substream-length mismatch). By contrast, all 2,048 inspected Glen Phillips sample headers had scrambling-control value 0. Together with American Beauty's MKB, this is strong evidence that its raw image still contains scrambled audio; neither authentication before `dd` nor the earlier video-only dvdbackup output supplied decrypted AOB data.

Inspected the official libdvdcss 1.6.0 source archive, whose SHA-256 matches the installed Homebrew formula (`7ea556c846b7bfc32d47b41cae56d1863a6b6d5f706bb162778d6f298490977c`). `src/cpxm.c` obtains the CPPM album ID using bus authentication and `ioctl_ReadDiscKey`. `src/libdvdcpxm.c` initializes CPPM using that ID and the MKB; its CPPM cache is a process-local linked list, not persistent state transferred from an earlier dvdbackup process. The installed public API does not provide an album-ID setter. Physical-drive authentication grants access to data/key material; it does not turn subsequent ordinary sector reads into a transparent CPPM-decrypted stream.

Implementation caution from source inspection: `dvdcpxm_init` can return the media type after clearing its protection state on initialization failure. Do not treat a returned CPPM media-type value alone as proof of working decryption. Verify resulting sector/decoder behavior and diagnostics.

The remaining requirement is obtaining/using the necessary protection information, not rebuilding the navigation inventory. Reusing the ISO with separately acquired initialization information needs further design; the stock drive path is still the first CPPM proof. Source archive: [VideoLAN libdvdcss 1.6.0](https://download.videolan.org/pub/videolan/libdvdcss/1.6.0/libdvdcss-1.6.0.tar.xz). Local probe results: `/private/tmp/silverside-american-raw-probe/report.json`. No physical drive was accessed in this check.

## Physical-drive experiments — 2026-10-31, evening

The user authorized read-only testing of all three inserted discs. Volumes were identified before reads: `AMERICAN_BEAUTY` on disk4, `DAD1021` on disk15, and `YES_FRAGILE` on disk16. These are session identifiers, not stable device choices. The user subsequently clarified that Fragile was in the ASUS and Classic Records in the BU50N; do not infer American Beauty's drive model from the earlier, conflicting placement description.

All probes used installed Homebrew libdvdread 7.1.1/libdvdcss 1.6.0 through public APIs, in separate processes per source. No custom decryption implementation was needed. The helper calls `DVDOpenAudio`, `DVDOpenFile(..., DVD_READ_TITLE_VOBS)`, and `DVDReadBlocks`; libdvdread handles DVD-Audio file selection and CPPM initialization/decryption. The video mode uses `DVDOpen` and the corresponding VOB read path.

### Authentication and sandbox finding

Inside the agent execution sandbox, physical navigation reads succeeded, but libdvdcss could not obtain copyright information through the drive ioctl. American Beauty's initial AOB output was byte-identical to the encrypted ISO sample and still had scrambling flags. Outside that sandbox, drive authentication succeeded and audio decoded correctly. This demonstrates why neither successful file reads nor successful inventory alone should be reported as successful decryption.

The agent's execution sandbox is distinct from code signing/library validation. These results do not imply a root requirement for a normal non-App-Sandboxed Developer ID helper. Subsequent probes disabled persistent CSS caching with `DVDCSS_CACHE=off`. The official libdvdread source archive was inspected for the public read-path behavior (archive SHA-256 matches Homebrew: `a0d47876548bec806774bbf8dbf20bb19ba139464383156b32eb8e59915b90a9`). Upstream source stays in the temporary experiment directory, not the Silverside engine.

### American Beauty: CPPM proof and complete first track

- Surround and stereo regions both decrypt through the installed libraries. All 4,096 inspected PES scrambling fields in each decrypted 8 MiB sample are zero; the corresponding raw-image samples were mostly scrambled.
- Both streams probe as MLP, 96 kHz/24-bit: six-channel `5.1` and two-channel `stereo`, respectively. Both decode cleanly.
- Read the full first surround track using ATS-relative sectors 0–173,513 inclusive. An independently initialized read of its first 8 MiB is byte-identical to the earlier decrypted sample.
- The resulting FLAC has 30,736,000 frames, exactly matching the ATS prediction: **320.166667 seconds**, 96 kHz/24-bit/5.1. Source-decoded PCM and decoded FLAC PCM SHA-256 both equal `37046bb91fd99c09ae92cc4599f70e9a1ce50a9e49cbd200bdbf11ae156e0007`.
- A 15-second stereo sample also passed the PCM round-trip and exact frame-count checks. Full-album extraction and joins across American Beauty's resetting per-track PTS remain untested.

This establishes the core protected DVD-Audio read/decode capability on macOS. It does not yet implement reusing encrypted ISO data with a separately obtained album ID, and does not require disc-image regeneration.

### Yes — Fragile: CPPM works after drive reconnect

- One audio title set and two video title sets. ATS has three rows: primary `0x81` (ten programs), secondary `0x01` (ten programs), and primary `0x82` (one one-second program).
- Both ten-program rows total **51:55.2325**, but **their individual track durations differ**. For example, the first surround program is 514.226667 s and the first stereo program 515.200000 s. Presentation-specific track boundaries are essential: do not reuse surround cuts for stereo just because album durations match.
- The initial sandboxed 8 MiB read timed out after 180 seconds and the drive disappeared from macOS. The user identified this as the ASUS and reported its tendency to need a reconnect after problematic operations. The user reconnected it; the same volume returned as disk16. Do not attribute the failure to the disc or claim the sandbox definitively caused the disconnect.
- A small unsandboxed retry then succeeded, followed by 8 MiB surround and stereo reads. Both probe/decode as 96 kHz/24-bit MLP (5.1 and stereo). The first 1 MiB from independent decrypted reads agrees exactly. A mounted raw-file read still has scrambling-control value 2 in 511 of 512 packets, showing that authentication did not transparently decrypt ordinary filesystem reads.
- A 10-second surround FLAC and a 15-second stereo FLAC passed source-to-FLAC PCM hashes and exact frame-count checks. The initial surround 15-second request correctly failed its length assertion because the bounded 8 MiB source contains only about 13.326 seconds; the final listening playlist includes the verified 10-second output instead.
- Full-track/album extraction and long-run ASUS reliability remain untested. Testing the disc in another drive remains useful, but basic CPPM support is now demonstrated on this drive after reconnect.

### Classic Records DAD1021: high-resolution DVD-Video audio

- The `AUDIO_TS` directory is empty. This is a DVD-Video source for these tests, not a DVD-Audio navigation source.
- One video title, one title set, 11 chapters. The inspected PGC has 11 programs and 11 cells, with each program starting at the correspondingly numbered cell; no angle/interleave flags were set, and every cell marks a timestamp discontinuity.
- Actual audio probes as `pcm_dvd`, **96 kHz/24-bit stereo**. This validates a second codec and the secondary DVD-Video extraction direction without requiring ffmpeg's absent `dvdvideo` demuxer: the helper reads the VOB data and ffmpeg demultiplexes/decodes it.
- Read first-cell sectors 0–59,758 inclusive. Extracted audio encodes to FLAC and decodes to identical PCM: SHA-256 `48a790758c560b7c232cd21f7df5e30ad5077eaafb9452ec4980a1cdc77518ea`, 19,801,600 frames (**206.266667 seconds**).
- ffmpeg reports a missing end PTS for video stream 1 in this cell-only segment. This specific video warning was reviewed and explicitly allowed; no audio decode/hash error was accepted. The utility saves the warning in the completion report.
- The PGC's video-derived first-cell duration is about 206.033367 seconds, different from all the audio carried in the extracted cell. Thus this is a verified lossless **first-cell audio extraction**, not proof of the exact intended chapter trim. Audio/video offsets, packet spillover and discontinuity handling need analysis before production chapter splitting. Do not trim solely by rounded DVD video time or silently discard the discrepancy.

### Artifacts, reproducibility and remaining work

Utilities: `scripts/dvd/inventory.c` (new `--device` mode), `video.c` (now also lists PGC/program/cell details), `read_blocks.c`, and `verify_segment.py`. The C utilities compiled with `-Wall -Wextra -Werror`; the segment verifier was exercised on MLP surround, MLP stereo and DVD LPCM. Logs/inventories/decrypted working segments are under `/private/tmp/silverside-dvd-hardware`.

Verified listening outputs and a playlist are under `/private/tmp/Silverside DVD Hardware Listening`. No ReplayGain or downmix was applied. Some failed exploratory directories remain for diagnosis; only outputs with `report.json` and included in `Verified samples.m3u8` are presented as completed. Source and output hashes use the same ffmpeg implementation, not independent decoder verification.

All three mounted discs were still present at the final device check. No eject, drive reset, region change, or disc write was performed. The user performed the ASUS reconnect. Next priorities are complete protected-program extraction with per-presentation boundaries, DVD-Video audio/chapter timing, and a stable helper protocol/capability report. Mixed-rate MLP, arbitrary channel layouts, malformed media handling, and signed/notarized helper packaging remain outside the proven scope.

## Full protected albums — 2026-11-01

The user inserted American Beauty in the MATSHITA BD-MLT UJ260AF and Fragile in the HL-DT-ST BD-RE BU50N, and authorized the full tests. DiskManagement confirmed the mounted volumes at `/dev/disk4` and `/dev/disk15` respectively. Fresh inventories matched the previous inventories exactly. No other drive was needed, and no disc was ejected, reset or written.

Both complete audio title-set reads exited successfully with exact expected lengths: American Beauty 1,966,811 sectors / 4,028,028,928 bytes (about 17.6 minutes), Fragile 1,906,182 sectors / 3,903,860,736 bytes (about 14.9 minutes). There were no short reads or timeouts. The first 8 MiB of each matches the previous decrypted sample, including Fragile's earlier ASUS read. All inspected first-private-stream PES scrambling fields were clear: 1,966,789 for American Beauty and 1,906,179 for Fragile; remaining sectors were not classified by that limited header check. These are complete AOB title sets, not complete decrypted DVD images with menus and video.

### Verified listening outputs

All four presentations are 96 kHz/24-bit FLAC, with 5.1 or stereo layout as selected. Each has continuous FLAC, numbered tracks, a track playlist and a completion report. No resampling, ReplayGain, downmix or optional dynamics processing was applied. Track titles remain placeholders.

| Presentation | Decoded frames | Duration | Navigation tracks |
|---|---:|---|---|
| American Beauty surround | 256,547,040 | 44:32.365 | 10 musical tracks + 1 second of exact digital silence |
| American Beauty stereo | 256,547,040 | 44:32.365 | 10 musical tracks + 1 second of exact digital silence |
| Fragile surround | 299,062,320 | 51:55.2325 | 10 |
| Fragile stereo | 299,062,320 | 51:55.2325 | 10 |

Fragile's separate third ATS title is also preserved and verified: one second / 96,000 frames of 5.1 digital silence. Its purpose has not been established; it is outside the main album playlists. American Beauty's silent terminal entry remains track 11 of each presentation so nothing is silently discarded.

For every selected track, the first audio PES timestamp agrees with ATS navigation, and duration converts exactly to an integer sample count. Every final FLAC has the expected format/length. Source-decoded PCM matches final FLAC PCM; joined track PCM matches continuous FLAC PCM. Fragile's stereo and surround track maps remain distinct: for example, track 2 begins at sample 49,459,200 in stereo versus 49,365,760 in surround (0.973333 seconds later). Its second surround cell also decoded independently to the same PCM as its continuous-program cut.

### Decoder state at American Beauty's boundaries

American Beauty resets PTS to 660 for every track, whereas Fragile's main titles have continuous timestamps. The first two American Beauty cells decoded as one stream with only the expected timestamp-reset diagnostic, and independent cell hashes agreed. But concatenating the full surround title into one ffmpeg decoder produced three MLP `Lossless check failed` warnings, within tracks 5, 8 and 10. The verifier rejected that output despite its correct total length. Fresh decodes of each affected cell had no warnings.

The completed American Beauty workflow therefore opens a fresh decoder for every self-contained cell, checks its source PCM hash and exact frame count, joins the lossless cell outputs into continuous FLAC, then checks all final split-track hashes against their source-cell hashes and joined-track PCM against the continuous result. Both surround and stereo passed with no diagnostics. Notably, the initially rejected surround decode's PCM hash is identical to the clean per-cell result: this test found an integrity-check-state problem, not a demonstrated sample difference. Do not broadly suppress integrity warnings or assume timestamp rewriting resets codec state. A general helper must communicate decoder boundaries and distinguish self-contained programs from continuous/gapless cells requiring preserved state or preroll.

These checks use the same FFmpeg implementation for source and FLAC decoding. They establish lossless conversion and sample continuity for these selected presentations, not independent-decoder consensus, every DVD-Audio layout, physical speaker routing or the intended musical meaning of every boundary. Listening at transitions remains useful.

### Reproduction, hashes and next work

Utilities are in `scripts/dvd/`: `read_blocks.c` now reports progress and has a 120-second operation alarm; `verify_program.py` adds constrained navigation-driven extraction/splitting, packet timestamp checks, source/FLAC/join hashes and optional fresh decoder state per cell. All final American Beauty runs used `--independent-cells --reset-decoder-per-cell`; Fragile's main presentations used continuous decoding. C compilation passed `-Wall -Wextra -Werror`, Python compilation passed, and the utilities were exercised on the complete hardware reads and all four presentations. No production Swift code changed.

Packed 24-bit interleaved PCM SHA-256 values:

| Presentation | SHA-256 |
|---|---|
| American Beauty surround | `ffbaa431f3881c13212f1733357f87cb438c5ea75493cbc165ac2b4b76be542e` |
| American Beauty stereo | `06623ffe99d84f988d9350052fb83bafc75099991b73966e722caecd17aedf55` |
| Fragile surround | `c8cdce8b38eb3ad25077388452ce727226568fd1b2e51b07b47ff4bd18dbc94e` |
| Fragile stereo | `9b64e98a8b5d34643cf45deb015e01f3a96332e7308b441d95f54ce4d24d178c` |

Listening files: `/private/tmp/Silverside DVD Full Albums`, with `Verified presentations.m3u8` and `READ ME.txt`. Copy desired tracks/continuous files and reports to permanent storage; the American Beauty `cells/` subdirectories are development intermediates. Inventories, decrypted title sets, source hashes, logs and failed experiments are retained under `/private/tmp/silverside-dvd-full-20261101`. Only outputs with a completed `listening-report.json` are presented as verified. Original raw ISOs were not modified.

Next: define the helper's versioned JSON inventory/extraction protocol, including presentation-specific track maps and decoder-reset boundaries. Then prototype a self-contained decrypted image from the preserved layout, covering the remaining protected menu/still/video assets and validating image-only reopening. DVD-Video chapter/audio alignment, general DVD-Audio LPCM/mixed-rate support, synthetic channel/boundary fixtures and production GUI integration remain outstanding. The four fetched upstream commits were inspected for overlap, including the GPLv3 and acknowledgment changes, but were not pulled into this checkout during the experiments.
