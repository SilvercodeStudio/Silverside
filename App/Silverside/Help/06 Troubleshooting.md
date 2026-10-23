# Troubleshooting

## Apple Music opens when I insert a disc

macOS opens Music for every audio CD, and Music has no setting that leaves the disc alone completely. The closest is “When a CD is inserted: Show CD” in the Music app's settings: Music still opens and comes to the front, but it does not play or import the disc. Then close Music, or leave it open. Do not let Music play or import the disc during a rip: two readers slow each other down.

## The disc could not be read

A disc takes a moment to mount after it appears. Try Again reads it once more. A disc that macOS cannot mount at all (a data disc in a format the Mac does not know) has no audio to rip.

## Not in MusicBrainz

The rip works. The names come from the disc's CD-Text, or you type them in the header and the track table, and the files get those names without MusicBrainz IDs. Better for everyone: add the release to MusicBrainz, then use Look Up Metadata before the rip.

## MP3 is not a choice

MP3 needs the LAME encoder (see Encoding under Settings). Install it with `brew install lame` in Terminal; Silverside notices it within a few seconds. Silverside looks for `lame` in `/opt/homebrew/bin`, `/usr/local/bin`, and the folders on its `PATH`. An app opened from the Finder does not get your shell's `PATH`, so a `lame` installed elsewhere is not found.

## The rip was not encoded

The rip stays in the rips folder, and the banner or the status bar says why:

- The library already had the album, and you chose Keep the Files.
- A track is not verified by AccurateRip or CTDB. Silverside encodes only verified rips; see Verification for what to try.
- MP3 is the format, but LAME is not installed.

To encode a kept rip later, use the command line: `silverside encode -i "<rip folder>"`, with `--allow-unverified` for tracks that no database verifies.

## Tracks are not accurate

See Verification. In short: clean the disc, rip again, or rip in another drive; the rips pool. A disc that is not in AccurateRip or CTDB cannot be verified, only read until the reads agree.

## A drive hangs on a damaged disc

Some drives retry a bad sector for a long time. Stop ends the rip after the read under way, but the drive may take a while to give up on that read. If the drive stops answering, eject the disc from the Finder and insert it again.

## Where are the settings and the profiles

`~/Library/Application Support/Silverside/` holds `settings.json`, `DriveProfiles.json`, and the releases you chose. `~/Library/Caches/Silverside/` keeps the answers from MusicBrainz, AccurateRip, and CTDB, so a disc you rip again sends no new requests.
