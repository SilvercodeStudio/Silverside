# App updates with Sparkle

A plan, discussed 2026-11-01, 2026-11-11, and 2026-11-12. All of it is done
(2026-11-12) but the test of a real update, from 0.9.6 to 0.9.7 (see the end).

## Decisions

- **Build number = version.** `CURRENT_PROJECT_VERSION` is
  `$(MARKETING_VERSION)` (done 2026-11-01), so `CFBundleVersion` is "0.9.3",
  as `CFBundleShortVersionString` is. Sparkle compares `CFBundleVersion`, part
  by part (0.9.10 is newer than 0.9.9), so each release must raise the
  version. A build number is for several builds of one version (betas, or the
  App Store, which wants a new number for each upload); Silverside needs
  neither. The About window shows the build only if it differs.
- **Automatic checks: Sparkle's default.** It asks at the second launch
  whether to check by itself. Settings › General gets the toggle.
- **The CLI goes inside the app,** with an optional install from a menu (see
  below), so an app update updates the CLI too.
- **A DMG with a background,** the window that shows the app and an arrow to
  Applications (see below).

Decided 2026-11-11:

- **Sparkle is an agreed dependency** (MIT, so it fits the GPL), 2.10.1 or
  later; 2.9 is the least for a signed feed. Credit it in NOTICE,
  Acknowledgments, and the site, and add it to the dependency line in
  CLAUDE.md.
- **Only a `make dist` build checks for updates:** the updater starts only
  when Info.plist has `SilversideArchive`. A build from source, or from `make
  install-app`, never replaces itself with a released one.
- **A signed feed:** `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction`
  (the first needs the second). `generate_appcast` signs the feed when the
  app's Info.plist asks for it; never edit `appcast.xml` by hand after that.
- **Release notes embedded in the feed,** as Markdown from the version's
  CHANGELOG entry (Sparkle 2.9, macOS 12), so no notes file needs a
  signature of its own. This replaces the notes pages below.
- **No XPC services:** an app without a sandbox does not use them. A build
  phase after the framework is copied removes them in an archive
  (`ACTION=install`), from Sparkle's "Removing XPC Services".
- **The zip first,** as `make dist` made it for 0.9.6; the DMG followed in a
  commit of its own (2026-11-12), and serves both the download button and
  Sparkle (Sparkle mounts a DMG and finds the app).
- **No delta updates at first** (`--maximum-deltas 0`): the 0.9.5 zip is
  11 MB. They can come later with no change to the app; `generate_appcast`
  needs the last few archives beside the new one, which the GitHub Releases
  keep.

## Parts

### Sparkle in the app (done 2026-11-11)

- Swift Package Manager, the app target only: the engine and the CLI do not
  link it. Pinned to an exact version (2.10.1) in the project: Xcode writes
  no pin for it, because the workspace's `Package.resolved` is SilversideKit's
  (it changed that file's `originHash` only). A new Sparkle is a change of the
  version in the project, and of `App/Silverside/Licenses/Sparkle.txt` if its
  LICENSE changed.
- `AppUpdater` (in `Model/`): one `SPUStandardUpdaterController`, made only
  with `SilversideArchive`; **Check for Updates…** after About in the app
  menu; "Check for updates automatically" in Settings › General, bound to
  `automaticallyChecksForUpdates` (Sparkle keeps it in the app's defaults). A
  build from source shows a line that says it does not check.
- Info.plist: `SUFeedURL` = `https://silverside.app/appcast.xml`,
  `SUPublicEDKey`, `SURequireSignedFeed`, `SUVerifyUpdateBeforeExtraction`. The
  feed is HTTPS, so it needs no App Transport Security exception. Sparkle's
  system profile stays off (its default).
- **No relaunch during work.** `AppModel.postponeRelaunch` holds "Install and
  Relaunch" while `hasWorkUnderWay` (a rip or its encoding, a busy drive, a
  repair, library work, Check Again, a video, the command line tool's
  install, and `workCount`: every task that changes earlier rips' covers,
  artwork, releases, or names, and the scans that write the history, from
  when it is asked for until it ends), says so in an alert unless one is on
  show, and installs when the work ends.
- The build phase "Remove Sparkle's XPC services" runs in an archive only:
  checked 2026-11-11 with an archive, the framework has no `XPCServices` and
  `codesign --verify --deep --strict` passes. The export with Developer ID
  signs `Autoupdate` and `Updater.app` again, and Apple notarized them (the
  0.9.6 `make dist`, 2026-11-11).
- Credits: Acknowledgments, the License sheet (Sparkle's whole LICENSE, with
  bsdiff's and the others' BSD texts, which a binary must reproduce), NOTICE
  (and `SilversideLicense.notice`), the site's home page and license page.
  The privacy page and the help (Settings, the files Silverside keeps) say
  what a check sends and where an update is kept.

### The signing key

- Sparkle's `generate_keys` makes an EdDSA key pair. The private key goes in
  the login Keychain; the public key into Info.plist. With no option it makes
  a key (or prints the one there); `-p` and `-x` only look one up.
- **Back up the private key** (`generate_keys -x <file>`), out of the repo; on
  another Mac, `generate_keys -f <file>` puts it back in the Keychain.
  Without it, the installed apps cannot check an update. (Sparkle can fall
  back on the Developer ID signature to change keys, but do not count on it;
  with `SUVerifyUpdateBeforeExtraction` that needs a DMG signed with
  Developer ID, and one update cannot change both the key and the
  certificate.)

### The feed and the files (done 2026-11-11)

- `appcast.xml` in `docs/site`, published by Pages with the rest of the site.
- The DMG in a GitHub Release (`gh release create 0.9.7 …`;
  the tags have no "v"), not in the repo: Pages refuses files over 100 MB, and
  a binary in Git stays in its history. The feed's links point at the
  release's files; Sparkle follows GitHub's redirects.
- `make dist` runs `generate_appcast` (the package's copy) on a folder with
  the feed as it is, the new DMG, and its notes: it adds the item (signature,
  size, versions, `minimumSystemVersion` 15.0), keeps the older items (at
  most 3, its default), and signs the feed. Tried 2026-11-11 with a throwaway
  key: an older item stays when its zip is not in the folder, and an app that
  is not validly signed is refused. With the app's key not the one it signs
  with, it warns and leaves the enclosure unsigned, so `make dist` checks the
  key first and the item's `sparkle:edSignature` after.
- Release notes: the version's CHANGELOG entry, embedded in the feed as
  Markdown (`--embed-release-notes`, `sparkle:format="markdown"`), not a page
  for each version.
- The steps of a release: `Releasing.md`.

### The CLI inside the app (done 2026-11-11, for 0.9.7)

- `silverside` in `Contents/Helpers/silverside`, and its completions in
  `Contents/Resources/Completions` (`_silverside`, `silverside.bash`,
  `silverside.fish`, made by the command itself). The build phase "Put the
  command line tool in the app" runs `make release` (a universal build with
  the commit's embedded Info.plist) in a Release build only, an archive or
  `make install-app`, with a clean environment, so SwiftPM does not see
  Xcode's settings. It signs the command with the hardened runtime (identifier
  `app.silverside.cli`); the export signs it again with Developer ID and a
  timestamp (checked 2026-11-11). It costs about 2 minutes on a first build,
  and adds about 19 MB to the app.
- **Install Command Line Tool…** (the app menu, and Settings › General), in a
  window of its own (`CommandLineToolView`, `CommandLineTool`): symbolic links
  in `make install`'s layout (`CommandLineInstall` in the engine, with tests),
  so each app update brings a new CLI. `/usr/local/bin` runs the links as the
  user first, then through `osascript … with administrator privileges`, which
  asks for the password; `~/.local/bin` needs none. The window reads the PATH
  of the user's login shell, says when `~/.local/bin` is not on it, and
  chooses that folder when it is. It knows a link to another copy of the app
  (moved, or deleted) and a copy from `make install`, which Install replaces;
  Remove takes away only links to a Silverside app. An app that macOS runs
  from a hidden copy (App Translocation) or a read-only disk image is told to
  move to Applications first.
- `make dist` checks the command: there, signed with Developer ID and the
  hardened runtime, of the app's version, with the three completions.
- `make install` stays for people who build from source.
- Not tried yet: the administrator's path on a Mac where `/usr/local` is not
  the user's, and the notarization of a build with the command (both at the
  0.9.7 release).

### The DMG (done 2026-11-12, for 0.9.7)

- `dmgbuild` (MIT, Python; agreed 2026-11-12), with `ds_store` and
  `mac_alias`, its own packages, at pinned versions. `make dist` puts them in
  a Python environment of their own, `build/tools/dmgbuild-<version>`, at
  the first use; nothing is installed for the whole Mac, and nothing is
  shipped. It writes the window's `.DS_Store` itself, with no Finder
  scripting.
- `App/DMG`: `dmg_settings.py` (the window, 660 × 400 points of picture; the
  app at (180, 180) and the link to `/Applications` at (480, 180), 128-point
  icons), `background.png` and `background@2x.png` (dmgbuild joins them into
  a two-image TIFF with `tiffutil -cathidpicheck`), and
  `make_dmg_background.py`, which draws them (numpy and Pillow; not run by
  the build). The volume's icon is the app's `AppIcon.icns`. The format is
  ULFO (LZFSE), HFS+.
- Found on macOS 27 (2026-11-12):
  - Finder counts the title bar (32 points) in the window's height, so the
    settings ask for 432.
  - Finder draws the icons' names in black on a picture, in the dark
    appearance too, so the picture is light (the light site's colors).
  - Finder's own path bar and status bar, when the user has them on, cover
    the lowest 56 points of the window; the settings cannot turn them off.
  - `hide_extensions` sets Finder information on the app, which fails
    `codesign --verify --strict` ("detritus"), so it is not used. Finder
    leaves out ".app" anyway, unless the user has it show every extension.
  - `hdiutil` warns that `create`, `attach`, and `convert` are deprecated in
    favor of `diskutil image`; they still work.
- `make dist` notarizes the app and staples it (so a copy dragged out opens
  with no network), builds the DMG, signs it with the app's Developer ID
  certificate, notarizes and staples it, and checks it: Gatekeeper accepts it
  (`spctl --type open`), and the app inside verifies, has its ticket, and has
  the link to `/Applications`. Two notarizations: a few more minutes.

### `make dist`

1. Archive and export with Developer ID; the CLI inside, signed. (Done
   2026-11-04, `scripts/dist.sh`; the CLI inside since 2026-11-11.)
2. Notarize and staple the app; build the DMG; sign, notarize, and staple it.
   (Done 2026-11-04 for a zip; the DMG since 2026-11-12.)
3. `generate_appcast`. (Done 2026-11-11.)
4. `gh release create`, with the DMG. (By hand: `Releasing.md`.)
5. Commit `appcast.xml` to `docs/site`, and push `main`. (By hand.)

Upload before the feed changes: a feed that points at a missing file fails for
everyone who checks then.

### Testing before the first release

- A build with a lower version finds the update, checks its signature,
  installs it, and relaunches. The plan: the 0.9.6 that `make dist` made
  (2026-11-11, installed in `~/Applications`, the only copy with Sparkle) and
  the 0.9.7 release's real feed.
- An update that arrives during a demo rip waits for the rip.
- **App Translocation:** an app opened from Downloads, not moved, runs from a
  read-only place, and Sparkle cannot replace it; Sparkle says so. Moving it
  to Applications by itself is a later nicety.
- The first public build must already have Sparkle: users of a build without
  it download the next one by hand.
