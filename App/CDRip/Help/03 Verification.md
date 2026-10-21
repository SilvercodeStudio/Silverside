# Verification

A rip is only as good as the check that proves it. CDRip uses two databases, and both are independent of the drive.

## AccurateRip

AccurateRip holds checksums of each track from many people's rips of the same disc. A track that matches is **accurate**: the data is bit for bit what other drives read. The number after it (conf 52) is how many rips agree. A track can also match **another pressing**: the same audio at a different alignment, which also proves it free of errors.

A disc that is not in AccurateRip cannot be proved this way. Then CDRip reads each track twice and reports whether the reads agree.

## CUETools database (CTDB)

CTDB checks the whole disc at once, and it holds repair data: when a few thousand samples are wrong, CTDB can correct them. CDRip tries a repair when AccurateRip says a track is wrong, then checks the repaired track against AccurateRip again. **Verified** means the disc matches an entry; **repaired** means it matches after the repair.

## Read offsets

Every drive reads a few samples early or late, by a fixed amount. CDRip corrects it, so rips from different drives come out the same, and AccurateRip checksums match. The offset comes from AccurateRip's list of drives, or from rips that confirm it. It is shown in Settings › Drives, where you can also set it by hand.

## What the statuses mean

| Status | Meaning |
|---|---|
| Copy OK, green | The track is verified by AccurateRip or CTDB. |
| Copied, grey | The track read the same each time, but no database can check it. |
| Sectors re-read, orange | Reads disagreed; the re-reads settled them. |
| Samples repaired, orange | CTDB corrected the track. It is verified now. |
| Sectors unresolved, red | Reads never agreed on these sectors. The track may have errors. |
| Not accurate, red | The track does not match AccurateRip, and no repair was possible. |

## When tracks stay unverified

- Clean the disc and rip again. The new rip pools with the first: sectors the first rip read right are kept.
- Rip in another drive. Each drive reads damage differently, so two drives together often get what one cannot.
- The command line's `cdrip repair` pools several rips of one disc and tries the CTDB repair again.
