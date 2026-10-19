# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

CDRip is a native macOS CD ripper. The goal is ripping quality equal to or better than Exact Audio Copy (EAC), with a modern UI and MusicBrainz-first metadata. It encodes to FLAC, ALAC, AAC, AIFF, and WAV. MP3 is out of scope.

The work is done in layers: engine library (`CDRipKit`), then a `cdrip` CLI, then the SwiftUI app (`CDRip/`). The app doesn't link `CDRipKit` yet.

Ripping is verification-first: rip fast with offset correction, verify each track against AccurateRip and CUETools DB (CTDB), and do secure re-reads only for tracks that don't match.

## Commands

```sh
make test        # swift test --package-path CDRipKit
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
- `CDDrive` is the hardware boundary. `SimulatedDrive` stands in for hardware in tests. It can simulate a read offset, overread, unreadable sectors (by requested LBA), and silent corruption (by physical sector). New drive behavior (cache, C2, subchannel, jitter) goes into both the protocol and the simulator, so you can test it without hardware.

## Verified vs. unverified

The test values in `DiscIDTests` are real data from MusicBrainz, AccurateRip, and CTDB. Don't change them to make a test pass.

- **Verified:** MusicBrainz disc IDs (all 20 discs of Grateful Dead *Summer Magic 1985*), AccurateRip disc IDs and URLs (two Nevermind pressings), CTDB TOC strings for audio-only discs, freedb IDs.
- **Not yet verified:** AccurateRip and CTDB rules for discs with data tracks, and the AccurateRip track checksum on real audio. A code comment marks each one. Verify them on hardware before you remove the comment.

## Constraints

- **Dependencies:** discuss each outside dependency with the user before you add it. Today the package has none. Prefer Apple frameworks: AudioToolbox encodes FLAC and ALAC, CryptoKit does SHA-1, and URLSession, IOKit, and DiskArbitration cover the rest.
- **Licensing:** the project will probably be open source under a permissive license such as MIT. Don't port GPL code. You may read whipper, libcdio-paranoia, XLD, and CUETools to understand an algorithm, but write our own implementation.
- **Distribution and access:** the app uses Developer ID distribution, not the App Store. App Sandbox is off, because ripping needs raw device access.
- **Platform versions:** Swift 6 language mode. The package's minimum is macOS 26, and the app targets macOS 27.
- **Network services:** MusicBrainz allows 1 request per second and needs a descriptive User-Agent. Don't put the user's email address in requests.
- **Hardware:** usually no drive is attached. The user has several external USB drives and a test kit of discs. Ask before you start work that needs one.

## Roadmap

1. Done: TOC, disc IDs, AccurateRip checksums, simulated drive, offset-corrected reader.
2. `cdrip` CLI (swift-argument-parser, still to be approved). A DiskArbitration and IOKit drive that uses the `DKIOCCDREAD*` ioctls on `/dev/rdiskN`. `drives` and `info` commands.
3. `cdrip rip --track N`: an offset-corrected rip, an AccurateRip lookup, and WAV output.
