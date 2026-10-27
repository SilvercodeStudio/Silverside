# Drives

Any drive that macOS sees as a CD drive works: USB, Thunderbolt, or a SATA drive in an enclosure. Silverside lists them in the sidebar with the disc in each.

## Settings › Drives

Each drive Silverside has seen has a profile:

- **Read offset.** The offset in use and where it came from: set by hand, confirmed by rips, or from AccurateRip's list of drives. A drive with no offset gets it from the list at its first online rip. An offset set by hand overrides the others; use it only when you know the drive's offset, for example from another ripper.
- **Rips.** The discs that checked the drive against AccurateRip, and the offsets they matched. Two or more discs that agree confirm the offset.
- **Cache.** Drives keep the last read in memory and return it again for a re-read, which would hide errors. Before a re-read, Silverside reads elsewhere on the disc to empty the cache. Measure Cache finds the size with timed reads and keeps it in the profile; an unmeasured drive gets a large, safe flush. A re-read of a track longer than the cache empties the cache by itself. When neither is possible, as for a short track on a disc with little other audio, a re-read may come from the cache: it does not count as a read that agrees, and the report says so.
- **Checks.** With a clean audio CD in the drive, Test Drive reads the TOC, audio from the middle of the disc, C2 flags, the Q subchannel, past the lead-out, and CD-Text, measures the cache, and times each check. Save Report writes the results with the drive's registry entries as JSON, for a bug report; `silverside drives --report` does the same.

## Ejecting

Eject in the toolbar unmounts and ejects the disc, as the Finder does. With "Eject the disc if every track is verified" on in Settings, a disc leaves the drive by itself after a good rip, and a disc with errors stays for another try.

## Several drives

Each drive rips on its own, so several discs can rip at once. Each rip claims its folder, so two rips of the same disc never write to one folder.
