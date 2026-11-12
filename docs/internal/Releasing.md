# Releasing Silverside

How to make a release of the app, publish it in the update feed, and start
the next version; and how to update Sparkle. The plan behind the updates is in
`Sparkle.md`.

## Versions

- **One version, in three places:** `MARKETING_VERSION` in
  `App/Silverside.xcodeproj/project.pbxproj` (Debug and Release), and
  `SilversideVersion.string` in `SilversideKit/Sources/SilversideKit/WebClient.swift`
  (the CLI and the User-Agent). `CURRENT_PROJECT_VERSION` is
  `$(MARKETING_VERSION)`, so `CFBundleVersion` is the same number.
- **Each release must be higher.** Sparkle compares `CFBundleVersion` part by
  part (0.9.10 is higher than 0.9.9) and offers only a higher one. A version
  that is in the feed can never be built again with other contents.
- **The tag** is the plain version (`0.9.6`, no "v"), annotated, on the commit
  that `make dist` built.
- **CHANGELOG.md:** the newest entry is `## 0.9.7 (not released yet)` while
  work goes on, and `## 0.9.7 (2026-11-20)` in the release's commit. The entry
  is also the update's notes, which Sparkle's window shows as Markdown: write
  it for the people who use Silverside.

## Set up a Mac for releases (once)

- **Xcode** signed in with the team (5A35N7A73U) and its Developer ID
  certificate.
- **The notary profile:** `xcrun notarytool store-credentials silverside
  --apple-id <Apple ID> --team-id 5A35N7A73U` (an app-specific password).
- **Sparkle's private key,** in the login Keychain under the account
  `silverside`. On a new Mac, put the backup from the password manager back:
  `generate_keys --account silverside -f <file>`, then delete the file.
  `generate_keys --account silverside -p` must print the `SUPublicEDKey` in
  `App/Silverside/Info.plist`. `generate_keys` is in the package's download
  (`SourcePackages/artifacts/sparkle/Sparkle/bin/` in the workspace's
  DerivedData, after a build) and in Sparkle's release archive.
  **Never make a new key:** every installed copy accepts only updates signed
  with this one. Sparkle has a way to change keys (an update signed with both
  the old key and the Developer ID certificate, in a DMG); avoid needing it.
- **GitHub's CLI:** `brew install gh`, then `gh auth login`. The release page
  on github.com works too.
- **Python 3** (`python3`; the one with Xcode's command line tools will do).
  `make dist` makes its own environment for dmgbuild in `build/tools` the
  first time, from the internet; there is nothing to install by hand.

Every step of a release that publishes something (a tag, a push, `gh`, the
feed's commit) is done by hand, by the maintainer, never by an agent.

## A release

1. **Finish the version.** Date the CHANGELOG heading. Change the version in
   `docs/site/index.html` (two lines, "Version 0.9.6 · Free and open
   source…"). Bring `Milestones.md` up to date. Run `make format`, `make
   lint`, `make test`, and `make build`, and commit ("Finish 0.9.7: …").
2. **`make dist`.** It needs a clean tree. It archives, exports with Developer
   ID, checks the signature (and that the `silverside` command inside is
   signed, of this version, with its completions), notarizes the app and
   staples it, puts it in a disk image, signs, notarizes, and staples that
   too (two waits of a few minutes each), checks it, and adds the version to
   the feed. The Keychain asks once whether `generate_keys` and
   `generate_appcast` may use the key: Always Allow. It leaves
   `build/dist/Silverside-0.9.7.dmg`, the notes
   `build/dist/feed/Silverside-0.9.7.md`, and a changed
   `docs/site/appcast.xml`.
   - `make dist FEED=0` makes the disk image only, for a build that is not to
     be published. Without a dated CHANGELOG heading, the feed step stops
     with a message (after the disk image is made).
   - `make dist` deletes `build/dist` first: upload the last release's disk
     image before the next try.
3. **Look at the feed's change** (`git diff docs/site/appcast.xml`): one new
   item with the version, the download URL under
   `releases/download/0.9.7/`, the notes, and `sparkle:edSignature` on the
   enclosure; the signature of the whole feed at the end. **Do not edit the
   feed:** a change breaks its signature, and every copy of the app then
   refuses it. To change the notes, edit the `.md` file in `build/dist/feed`
   and run `generate_appcast` again on that folder, with the options in
   `scripts/dist.sh`, then copy its `appcast.xml` to `docs/site`.
4. **Tag and push the tag:** `git tag -a 0.9.7 -m 0.9.7` on the commit that
   was built, then `git push origin 0.9.7`.
5. **Upload the disk image** before the feed names it: `gh release create
   0.9.7 build/dist/Silverside-0.9.7.dmg --title "Silverside 0.9.7"
   --notes-file build/dist/feed/Silverside-0.9.7.md`. Check that the download
   works:
   `curl -sIL https://github.com/SilvercodeStudio/Silverside/releases/download/0.9.7/Silverside-0.9.7.dmg`
   ends in `200`, with the disk image's size.
6. **Publish the feed:** commit `docs/site/appcast.xml` alone ("Publish 0.9.7
   in the update feed") and push `main`. The Pages workflow publishes it in a
   minute or two; `curl -s https://silverside.app/appcast.xml` then shows the
   new item.
7. **Check the update** on a Mac with the release before: Silverside › Check
   for Updates… finds the new version, shows its notes, installs it, and opens
   it again; About shows the new version. Install a test copy from the disk
   image, or with the Finder or `ditto`: a copy that follows symbolic links (`cp -L`,
   some sync tools) turns Sparkle.framework's links into folders, and its
   signature no longer holds (`codesign --verify --deep --strict` says "bundle
   format is ambiguous").
8. **Start the next version:** raise the version in the three places, and add
   `## 0.9.8 (not released yet)` to CHANGELOG.md. Commit.

## When something goes wrong

- **Notarization fails:** `make dist` prints Apple's log. Fix, commit, and run
  it again; the version stays the same while nothing is published.
- **A published release is bad:** release a higher version with the fix.
  Sparkle never goes down a version. To stop offering the bad one at once,
  revert the feed's commit and push: the earlier feed is still signed. Copies
  that already updated stay on it until the next version.
- **The feed was edited by hand:** run `generate_appcast` again (step 3), or
  revert it.

## The disk image's window

`App/DMG/dmg_settings.py` lays it out for dmgbuild, over `background.png`
and `background@2x.png`. `make_dmg_background.py` draws the pictures (it needs
numpy and Pillow: `python3 -m venv /tmp/bg && /tmp/bg/bin/pip install numpy
pillow`, then `/tmp/bg/bin/python App/DMG/make_dmg_background.py App/DMG`).
The window's size and the icons' places are in both files; keep them the
same. To look at the window without a release, make a disk image from any
copy of the app with the dmgbuild in `build/tools`:

```sh
build/tools/dmgbuild-1.6.7/bin/dmgbuild -s App/DMG/dmg_settings.py \
    -D app=<path to Silverside.app> Silverside /tmp/Try.dmg && open /tmp/Try.dmg
```

Finder writes the names under the icons in black on a picture, in both
appearances, so the picture must be light enough behind them.

## Updating Sparkle

The package is pinned to one version in the project (`XCRemoteSwiftPackageReference
"Sparkle"`, `version = 2.10.1;`), because Xcode records no pin for it.

1. Read Sparkle's release notes for changes to the XPC services, the
   Info.plist keys, or the feed.
2. Change the version in the project: in Xcode (the project › Package
   Dependencies), or the `version` line in `project.pbxproj`.
3. `make build`, then a try: `ALLOW_DIRTY=1 NOTARIZE=0 make dist` (it deletes
   `build/dist`). It fails if the XPC services are still in the app, which
   means that the build phase "Remove Sparkle's XPC services" needs the new
   paths.
4. If Sparkle's `LICENSE` changed, copy it to
   `App/Silverside/Licenses/Sparkle.txt`, and update the list of code under
   other licenses on `docs/site/license.html`.
5. Change the version in `Sparkle.md`.

`make dist` uses the tools of the package that the archive used, so they
change with it.
