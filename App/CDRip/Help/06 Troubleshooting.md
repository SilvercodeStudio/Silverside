# Troubleshooting

## Apple Music opens when I insert a disc

macOS opens Music for every audio CD, and Music has no "do nothing" setting. CDRip reads the disc while Music shows it; close Music or leave it. Do not let Music import the disc at the same time as a rip: two readers slow each other down. You can set "When CD inserted: Show" as the default action in AM Settings, to avoid automatically playing or ripping the CD through Apple Music.

## The disc could not be read

A disc takes a moment to mount after it appears. Try Again reads it once more. A disc that macOS cannot mount at all (a data disc in a format the Mac does not know) has no audio to rip.

## Not in MusicBrainz

The rip works, and the folder is named after the disc ID. The files cannot be tagged until the release is in MusicBrainz. Add the release there, then look up the disc again.

## Tracks are not accurate

See Verification. In short: clean the disc, rip again, or rip in another drive; the rips pool. A disc that is not in AccurateRip or CTDB cannot be verified, only read until the reads agree.

## A drive hangs on a damaged disc

Some drives retry a bad sector for a long time. Stop ends the rip after the read under way, but the drive may take a while to give up on that read. If the drive stops answering, eject the disc from the Finder and insert it again.

## Where are the settings and the profiles

`~/Library/Application Support/CDRip/` holds `settings.json`, `DriveProfiles.json`, and the releases you chose. `~/Library/Caches/CDRip/` keeps the answers from MusicBrainz, AccurateRip, and CTDB, so a disc you rip again sends no new requests.
