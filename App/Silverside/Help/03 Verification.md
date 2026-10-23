# Verification

A rip is only as good as the check that proves it. Silverside uses two databases, and both are independent of the drive.

## AccurateRip

AccurateRip holds checksums of each track from many people's rips of the same disc. A track that matches is **accurate**: the data is bit for bit what other drives read. The number after it (conf 52) is how many rips agree. A track can also match **another pressing**: the same audio at a different alignment, which also proves it free of errors.

A disc that is not in AccurateRip cannot be proved this way. Then Silverside reads each track twice and reports whether the reads agree.

## CUETools database (CTDB)

CTDB checks the whole disc at once, so a rip of some tracks only is not checked. It also holds repair data: when a few thousand samples are wrong, CTDB can correct them. Silverside tries a repair when a track is not verified, then checks the repaired track against AccurateRip again. **Verified** means the disc matches an entry; **repaired** means it matches after the repair.

## Read offsets

Every drive reads a few samples early or late, by a fixed amount. Silverside corrects it, so rips from different drives come out the same, and AccurateRip checksums match. The offset comes from AccurateRip's list of drives, or from rips that confirm it. It is shown in Settings › Drives, where you can also set it by hand.

## What the statuses mean

| Status | Meaning |
|---|---|
| Verified, green | AccurateRip or CTDB verifies the track. |
| Repaired, orange | CTDB's repair data corrected the track, and the result is verified. |
| Copied, grey | The reads agree, but no database has this disc to check against. |
| Not verified, red | No database matches the track, and a repair was not possible. |

The Re-reads column counts the sectors that were read again (in red when some never agreed), and the Repaired column the samples that CTDB corrected.

## When tracks stay unverified

The result banner says what is most likely to help next. In short:

- Clean the disc and rip again. The new rip pools with the first (see Options under Ripping a Disc): a track that either rip got accurate is kept.
- Rip in another drive. Each drive reads damage differently, so two drives together often get what one cannot.
- Repair the rip.

## Repair

Repair, in the toolbar of an earlier rip and in the Disc menu, checks the rip against CTDB again and repairs it with CTDB's data, as `silverside repair` does. Every other rip of the same disc in the rips folder joins the pool. When the disc is in a drive that is free, the sectors where the repair still fails are read again, which gives it more versions to try.

A rip that CTDB verifies as it is gets its report brought up to date: a rip made offline becomes a verified rip. A rip that the repair changes stays as it was, and the repaired rip goes in a folder of its own next to it ("… repaired"), with its own report, so it can be encoded like any rip.

## Multi-disc sets

The discs of one release share their release choice and the album's edits, and the chips say how far the set is: "Disc 2 of 3" for the disc in the drive, and how many discs of the set are ripped. The sidebar names each disc of a set.
