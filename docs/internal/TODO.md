**Icon Composer.** On macOS 26 and later, app icons are "Liquid Glass": the system renders them from layers, adds the glass highlights and depth itself, and derives the dark, clear, and tinted appearances a user can pick in System Settings. An Icon Composer document (`AppIcon.icon`, which your eXoMAC project already has two of) supplies those layers. A classic `AppIcon.appiconset` like ours still works, which is what you see now, but the system treats it as a flat picture: it gets the rounded glass frame and nothing else, and in the dark, clear, and tinted modes it shows the same flat art inside the frame rather than a proper variant. On macOS 15, where the app also runs, the appiconset is all there is, so both stay in the project. The work is to rebuild the B2 and C2 art as layers (disc, laser arm, bezel, waveform) in Icon Composer, which is design work rather than code, and the design artifact's source layers would be the starting point.

**The other missing items**, as they stand after today:

- **Untested on hardware from the app:** a complete rip, Stop, Eject, encode after rip, and now the edits flowing through to tags. Your next session covers most of this.
- **Editing after the rip in the app:** an earlier rip's names can be changed only with `cdrip metadata -i folder --set ...` for now. Track artists are editable in the CLI but not yet in the app's table.
- **Repair from the app:** pooling rips from several drives and re-running the CTDB repair is CLI only. Related: advice after an unverified rip about what to try next.
- **Per-rip choices the CLI has:** an output folder, a pool of earlier rips, offline mode. Fast mode is not remembered between launches.
- **Live graph and background feedback:** the error strip is the only per-sector view; no Dock progress or notification when a rip finishes behind another app.
- **Settings › Drives:** no drive test or cache measurement from the app, and no vendor aliases for AccurateRip's drive list.
- **Recent Rips** lists only the rips folder, not the reports kept in the library's album folders.
- **Engine limits:** partial rips are not checked against CTDB; a drive stuck on a bad sector cannot be interrupted mid-read; pre-emphasis is marked but not applied; enhanced CDs and hidden track one audio have never met a real disc.
- **Milestone 9:** multi-disc sets as one unit beyond the shared album edits, and style recipes.
- **Shipping:** About window, Icon Composer icon, Developer ID signing and notarization.
-
