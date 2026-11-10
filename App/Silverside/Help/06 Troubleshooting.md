# Troubleshooting

<!-- toc -->

## Apple Music opens when I insert a disc

macOS opens Music for every audio CD. To stop it, open System Settings › CDs & DVDs and set "When you insert a music CD" to Ignore. The CDs & DVDs settings show only while an optical drive is connected.

If you want Music to open but not touch the disc, set "When a CD is inserted" to Show CD in the Music app's settings instead. Do not let Music play or import the disc during a rip: two readers slow each other down.

The same Ignore setting from Terminal, if the CDs & DVDs settings do not show:

```
defaults write com.apple.digihub com.apple.digihub.cd.music.appeared -dict action 1
killall SystemUIServer
```

The second line restarts the part of macOS that handles discs (the menu bar flickers once). To undo it, set the choice back in CDs & DVDs, or:

```
defaults delete com.apple.digihub com.apple.digihub.cd.music.appeared
killall SystemUIServer
```

## The disc could not be read

A disc takes a moment to mount after it appears. Try Again reads it once more. A disc that macOS cannot mount at all (a data disc in a format the Mac does not know) has no audio to rip.

## Not in MusicBrainz

The rip works. The names come from the disc's CD-Text, or you type them in the header and the track table, and the files get those names without MusicBrainz IDs. Better for everyone: add the release to MusicBrainz, then use Look Up Metadata before the rip.

## MP3 is not a choice

MP3 needs the LAME encoder (see [Encoding](help:settings#encoding) in Settings). Install it with `brew install lame` in Terminal; Silverside notices it within a few seconds. Silverside looks for `lame` in `/opt/homebrew/bin`, `/usr/local/bin`, and the folders on its `PATH`. An app opened from the Finder does not get your shell's `PATH`, so a `lame` installed elsewhere is not found.

## The rip was not encoded

The rip stays in the rips folder, and the banner or the status bar says why:

- The library already had the album, and you chose Keep the Files.
- A track is not verified by AccurateRip or CTDB, or no database has the disc. Silverside encodes only verified rips; see [Verification](help:verification#when-tracks-stay-unverified) for what to try. To encode it as it is, listen to it, then click **Encode…** in the banner.
- MP3 is the format, but LAME is not installed.

To encode a kept rip later, select it in Recent Rips and click **Encode**, or for a set, use **Encode Discs** in the set's view. For a rip with tracks that no database verifies, **Encode…** asks you to accept it as it is first (see [Verification](help:verification#when-tracks-stay-unverified)).

## A disc was not ripped when it went in

With "Rip it at once" on (Settings › General), a disc rips by itself only when MusicBrainz names its release for certain and the disc has no earlier rip. The status bar says which of these held it back. A disc that is in a drive when Silverside starts waits for you too. Choose a release, or click Rip Disc.

## Music did not get the files

"Add the files to the Music app" does nothing for FLAC, which Music cannot read; choose Apple Lossless. If the banner says Silverside may not control Music, you said no when macOS asked, or the question did not show: allow Silverside under System Settings › Privacy & Security › Automation, so the next album goes in. For the album that did not, drag its folder from the library onto Music's window.

## Tracks are not accurate

See [Verification](help:verification#when-tracks-stay-unverified). In short: clean the disc, rip again, or rip in another drive; the rips pool. A disc that is not in AccurateRip or CTDB cannot be verified, only read until the reads agree.

## A drive hangs on a damaged disc

Some drives retry a bad sector for a long time. Stop ends the rip after the read under way, but the drive may take a while to give up on that read. If the drive stops answering, eject the disc from the Finder and insert it again.

## Report a problem

Help › Report a Problem… opens a new issue for Silverside on GitHub in your browser. The issue has headings for you to fill in, and at its end Silverside's version, your macOS version and Mac model, and each drive with its read offset. Nothing is sent until you submit the issue, and you can change or delete any of it first. You need a GitHub account to submit.

Attach the files that show the problem:

- For a rip, its `Rip Report.log` or `disc.json`, from the rip's folder. Control-click a rip in the sidebar and choose Show in Finder.
- For a drive, its report: Settings › Drives › Save Report.

## Send feedback

Comments, ideas, and questions that are not about a problem are welcome too. Help › Send Feedback… opens a new discussion for Silverside on GitHub, with Silverside's version and your macOS version at its end. As with a problem report, nothing is sent until you submit it.

## Where Silverside keeps its files

Silverside and the `silverside` command share these files. In `~/Library/Application Support/Silverside/`:

- `settings.json`: the settings.
- `DriveProfiles.json`: each drive's read offset, the discs that confirmed it, its cache size, and its test results.
- `ReleaseChoices.json`: the release you chose for each disc.
- `ReleaseEdits.json`: the album names you changed, kept by release, so every disc of a set gets them.
- `CustomSets.json`: your custom sets.
- `ReleaseCovers/`: the covers you chose, by release.
- `History/`: a copy of each rip's report, so that Rip History keeps rips whose files you moved or deleted.
- Files that end in `.lock` let the app and the command use the files at the same time.

Elsewhere:

- `~/Library/Caches/Silverside/`: the answers from MusicBrainz, the Cover Art Archive, AccurateRip, and CTDB, so a disc you rip again sends no new requests. You can delete it at any time; the next lookup asks again.
- `~/Library/Preferences/app.silverside.Silverside.plist`: the app's own choices, such as the track table's columns.

Your music is in the folders that Settings names: the Music library (`~/Music/Silverside Library` at first) and the Rips (`~/Music/Silverside Rips`) in General, and the disc images (`~/Music/Silverside Images`) in Encoding. The Rips folder also holds `.silverside-rip-locks`, which keeps two rips out of one folder. The folder at the bottom of the sidebar opens the library in the Finder, or the Rips folder when rips are not encoded; hold Option for the other one.

To move the library, to a NAS for example, quit Silverside, copy the library folder to its new place, then choose that place for the Music library in Settings › General. Each album's report finds its album where the report is, and a rip's report keeps its album's place relative to the library, so nothing else needs to change. Check that your rips show and play from the new place before you delete the old copy.

To remove Silverside, quit it, move it to the Trash, and delete the two `Silverside` folders and the `.plist` file above. Your music folders stay as they are. Keep `Application Support/Silverside` if you may install Silverside again: it has your drives' offsets and your rip history.
