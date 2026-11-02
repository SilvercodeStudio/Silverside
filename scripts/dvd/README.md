# DVD inventory experiments

Development utilities for the exploration in [DVD.md](../../docs/internal/DVD.md), not production Silverside commands. The C clients retain their explicit GPL-2.0-or-later notices; their final packaging is undecided. They use public libdvdread APIs and are not linked into Silverside.

The selected production dependency policy is user-installed Homebrew libraries,
with DVD extraction unavailable when they are absent. Silverside will not bundle
or download libdvdread/libdvdcss. These research clients directly link to the
local libdvdread; the proposed shipped helper will instead load it at runtime so
it can start and report dependency availability even without the libraries.

- `inventory.c`: read-only DVD-Audio navigation inventory from an image, through stream callbacks (no physical device access).
- `video.c`: DVD-Video title/stream/chapter inventory from an existing backup directory.
- `inspect_images.py`: ISO9660 file inventory, checks against the audio reports, JSON output, and a small Glen Phillips stream probe. It is deliberately tailored to the two named, single-audio-title-set test images. It does not support arbitrary UDF-only or multi-extent images. Do not run Python with `-O`, which disables its validation assertions.
- `verify_sample.py`: a three-second MLP → FLAC → PCM check for the Glen Phillips sample. Requires 96 kHz, 24-bit, 5.1 output and byte-identical decoded PCM. Rebuilds timestamps from decoded sample count with `asetpts`; this changes timing metadata, not audio samples, and is only suitable here because the sample is continuous. It is not a general solution to DVD navigation discontinuities.
- `listen_glen.py`: one-off full-program FLAC extraction from the inventoried Glen Phillips image; `--presentation surround` (default) or `--presentation stereo` (the encoded MLP stereo substream). Uses provisional track cuts from exact sample counts derived from ATS durations. Checks total and per-track lengths, hashes source-decoded PCM before FLAC encoding, and compares both continuous and joined-track FLAC PCM against it. Writes a playlist and JSON report; refuses to overwrite an existing output directory. This is specific to this unprotected test disc and does not handle arbitrary navigation, CPPM, or general presentation discovery. Completion requires a `listening-report.json`; interrupted jobs may leave incomplete media files. It is not a production job/resume implementation.
- `compare_stereo.py`: creates matching 30-second clips (program seconds 60–90) from the authored stereo FLAC and ffmpeg's default downmix of the surround FLAC. Reports sample hashes, correlation, and residual differences after fitting a scalar gain independently for each channel. It does not rank audio quality or claim the generic downmix matches any particular player's behavior.
- `probe_raw_audio.py`: takes a bounded raw AOB sample from each inventoried ATS row, counts private-stream PES scrambling-control values, and attempts a one-second direct decode. For the known single-title-set images only; writes samples and diagnostics outside the repository. A decode failure alone does not prove encryption, and this does not attempt CPPM decryption.
- `inventory.c --device SOURCE`: explicit device-backed DVD-Audio inventory (the original one-argument form still uses file-stream callbacks). Device authentication needs access to macOS drive ioctls.
- `read_blocks.c`: read-only libdvdread helper for audio AOB or video VOB title-set blocks. Arguments: `audio|video SOURCE TITLE_SET START COUNT OUTPUT`. START is relative to the concatenated title-set AOB/VOB files, COUNT is in 2,048-byte sectors. Creates OUTPUT exclusively; never overwrites it. Reports progress every ten seconds and limits library open/read/close operations to 120 seconds with an alarm (a kernel-blocked device operation may delay signal delivery). Cancellation or failure may leave a partial file; only a zero process exit and the exact expected byte count establish a completed read. Use only a confirmed current source/device and validated navigation extents. A successful read does not establish decryption: probe and decode the result. Run one source per process; protection/library state is not a multi-drive abstraction.
- `verify_segment.py`: transcodes a completed extracted segment to 24-bit FLAC, hashes source-decoded PCM and decoded FLAC PCM, and verifies an optional expected frame count. Supports a bounded `--seconds` sample. `--allow-missing-video-end-pts` accepts only the specific MPEG video-stream-1 missing-end-PTS warning observed on the Classic Records first-cell sample; all other warnings still stop verification. This is a development probe, not general warning suppression. Only a completed `report.json` signifies success.
- `verify_program.py`: selects a contiguous presentation from decrypted title-set AOB data using the text inventory; all selected sectors must already be present. Requires one cell per track and integer 96 kHz sample counts from ATS durations, and checks first-packet PTS against each navigation entry. Encodes continuous 24-bit FLAC, splits at exact sample offsets, checks output format/length, and compares source PCM against continuous and joined-track PCM. `--independent-cells` additionally compares fresh cell decodes to the split tracks for self-contained cells such as American Beauty's. Refuses output directories that already exist and stops on decoder warnings, except narrowly validated timestamp-reset diagnostics matching reset-per-track navigation (which requires independent-cell verification). Only `listening-report.json` establishes presentation verification; source-read completion is recorded separately. This is a constrained research workflow, not a general navigation engine or proof of editorial boundary correctness.

American Beauty requires `--reset-decoder-per-cell --independent-cells` for the
clean full-program workflow tested here. Concatenating its independently clocked
MLP cells into one decoder produced lossless-check warnings, whereas fresh cell
decodes were clean. The reset mode verifies every cell's length and source PCM,
joins lossless cell outputs into continuous FLAC, then verifies every final track
against its source-cell hash and the joined tracks against continuous PCM. It
keeps intermediate cell FLACs under `cells/`. Do not suppress MLP integrity
warnings or assume `asetpts` resets codec state. Fragile's main presentations use
continuous decoding without this option.

### Physical-disc notes

The 2026-10-31 tests used libdvdread 7.1.1 and libdvdcss 1.6.0 from Homebrew. Authentication failed inside the agent's execution sandbox even though plain sector reads succeeded; an unsandboxed process decrypted American Beauty and Fragile successfully. This is not a requirement to run the production helper as root. The existing Developer ID app design is not App Sandboxed; library validation and raw-device permissions remain separate concerns.

Use `DVDCSS_CACHE=off` for repeatable scratch runs that need not write a persistent CSS cache. Avoid verbose key-bearing diagnostics in published reports. Do not hard-code the device numbers from the test notes: re-identify the mounted volume first. Wrap physical experiments in appropriate timeouts; the ASUS disappeared during the initial sandboxed Fragile read and required a user reconnect. The reconnect and unsandboxed retry succeeded, but causation and reliability across other discs are not established.

Example build and read (substitute a freshly verified device and extents):

```sh
clang -Wall -Wextra -Werror -I"$DVD_BREW_PREFIX/include" scripts/dvd/read_blocks.c \
  -L"$DVD_BREW_PREFIX/lib" -ldvdread -o "$DVD_WORK/read_blocks"
DVDCSS_CACHE=off "$DVD_WORK/read_blocks" audio /dev/rdiskN 1 0 512 "$DVD_WORK/sample.aob"
python3 scripts/dvd/verify_segment.py "$DVD_WORK/sample.aob" "$DVD_WORK/verified-sample" \
  --title 'DVD-Audio sample' --seconds 1 --frames 96000
```

The example frame count assumes 96 kHz; verify the stream format first. `video.c` now also lists PGC program-to-cell mappings and cell sector ranges, angle/interleave/discontinuity flags, and raw BCD playback times. Those video times alone do not establish sample-accurate audio cuts.

Full-presentation verification after a successful complete title-set read (the
source starts at title-set sector zero; these title-row choices are specific to
the inventoried American Beauty disc):

```sh
python3 scripts/dvd/verify_program.py "$DVD_WORK/american-ats01.aob" \
  "$DVD_WORK/american-inventory.txt" "$DVD_WORK/American Beauty - Surround" \
  --title-row 1 --artist 'Grateful Dead' --album 'American Beauty' \
  --presentation surround --independent-cells --reset-decoder-per-cell
python3 scripts/dvd/verify_program.py "$DVD_WORK/american-ats01.aob" \
  "$DVD_WORK/american-inventory.txt" "$DVD_WORK/American Beauty - Stereo" \
  --title-row 2 --artist 'Grateful Dead' --album 'American Beauty' \
  --presentation stereo --independent-cells --reset-decoder-per-cell
```

`--track-count N` restricts a diagnostic run to the first N tracks. The output
directory must be new. Track names are placeholders; navigation-derived programs
can include short nonmusical terminal entries. Keep those until their content
and navigation role have been examined. The script preserves both continuous
FLAC and individual tracks, so allow space for both.

Requires Homebrew `libdvdread` and `ffmpeg`, Python 3, and Apple command-line developer tools to build the probes. End users of a future bundled helper would not need the compiler or Python.

Example (generated files stay outside the repository):

```sh
DVD_WORK=/private/tmp/silverside-dvd-inventory
DVD_BREW_PREFIX="$(brew --prefix)"
mkdir -p "$DVD_WORK"
clang -Wall -Wextra -Werror -I"$DVD_BREW_PREFIX/include" \
  scripts/dvd/inventory.c -L"$DVD_BREW_PREFIX/lib" -ldvdread \
  -o "$DVD_WORK/inventory"
clang -Wall -Wextra -Werror -I"$DVD_BREW_PREFIX/include" \
  scripts/dvd/video.c -L"$DVD_BREW_PREFIX/lib" -ldvdread \
  -o "$DVD_WORK/video"

"$DVD_WORK/inventory" "$HOME/Movies/DVD/Glen Phillips raw.iso" \
  > "$DVD_WORK/glen-phillips.txt" 2> "$DVD_WORK/glen-phillips.stderr"
"$DVD_WORK/inventory" "$HOME/Movies/DVD/American Beauty DVD-A raw.iso" \
  > "$DVD_WORK/american-beauty.txt" 2> "$DVD_WORK/american-beauty.stderr"
"$DVD_WORK/video" "$HOME/Movies/DVD/Glen Phillips" \
  > "$DVD_WORK/glen-phillips-video.txt" 2> "$DVD_WORK/glen-phillips-video.stderr"
"$DVD_WORK/video" "$HOME/Movies/DVD/American Beauty" \
  > "$DVD_WORK/american-beauty-video.txt" 2> "$DVD_WORK/american-beauty-video.stderr"

python3 scripts/dvd/inspect_images.py --images "$HOME/Movies/DVD" --output "$DVD_WORK"
python3 scripts/dvd/verify_sample.py "$DVD_WORK/glen-first-4MiB.aob" "$DVD_WORK/glen-3s.flac"
python3 scripts/dvd/listen_glen.py "$DVD_WORK/glen-phillips.json" \
  '/private/tmp/Silverside DVD Listening - Glen Phillips'
python3 scripts/dvd/listen_glen.py "$DVD_WORK/glen-phillips.json" \
  '/private/tmp/Silverside DVD Listening - Glen Phillips Authored Stereo' --presentation stereo
python3 scripts/dvd/compare_stereo.py \
  '/private/tmp/Silverside DVD Listening - Glen Phillips Authored Stereo/Glen Phillips - stereo.flac' \
  '/private/tmp/Silverside DVD Listening - Glen Phillips/Glen Phillips - 5.1.flac' \
  '/private/tmp/Silverside DVD Stereo Comparison'
```

Check exit codes and stderr separately. A parsed inventory does not establish decryption or a correct full-program decode. These scratch C clients trust libdvdread's parsed arrays and are not hardened against arbitrary damaged input. The Python utility writes a copyrighted 4 MiB AOB sample alongside its reports; do not commit or distribute generated media.
