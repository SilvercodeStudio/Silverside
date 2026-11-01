# App updates with Sparkle

A plan, discussed 2026-11-01. Not started. It comes after the work for a
notarized release (a Developer ID team in the project, the hardened runtime,
`notarytool`), which it needs.

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

## Still to decide

- Sparkle is an outside dependency (CLAUDE.md asks to discuss each one). It is
  MIT-licensed, so it fits the GPL; it needs a credit in Acknowledgments and on
  the site.
- One archive or two: the DMG serves both the download button and Sparkle
  (Sparkle mounts a DMG and finds the app), or a zip for Sparkle beside it.
  One DMG keeps the release simple.

## Parts

### Sparkle in the app

- Swift Package Manager, the app target only: the engine and the CLI do not
  link it.
- One `SPUStandardUpdaterController`; **Check for Updates…** in the app menu;
  "Automatically check for updates" in Settings › General.
- Info.plist: `SUFeedURL` = `https://silverside.app/appcast.xml`, and
  `SUPublicEDKey`. The feed is HTTPS, so it needs no App Transport Security
  exception. Leave Sparkle's system profile off.
- **No relaunch during a rip.** "Install and Relaunch" would quit a rip,
  encoding, or repair in the middle. The delegate's
  `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)` holds the
  relaunch until the work ends.
- The site's privacy page gets a line: an update check sends the app's version
  and the IP address to GitHub Pages.

### The signing key

- Sparkle's `generate_keys` makes an EdDSA key pair. The private key goes in
  the login Keychain; the public key into Info.plist.
- **Back up the private key** (`generate_keys -x <file>`), out of the repo.
  Without it, the installed apps cannot check an update. (Sparkle can fall
  back on the Developer ID signature to change keys, but do not count on it.)

### The feed and the files

- `appcast.xml` in `docs/site`, published by Pages with the rest of the site.
- The DMG in a GitHub Release (`gh release create v0.9.3 …`), not in the repo:
  Pages refuses files over 100 MB, and a binary in Git stays in its history.
  The feed's links point at the release's files; Sparkle follows GitHub's
  redirects.
- `generate_appcast` writes the feed from a folder of the archives: the
  signature, size, versions, `minimumSystemVersion` 15.0, and delta updates
  (much smaller downloads), if wanted.
- Release notes: a page for each version, `docs/site/releases/0.9.3.html`,
  made from that version's CHANGELOG entry, in the site's style; the feed
  links to it.

### The CLI inside the app

- `silverside` in `Contents/Helpers/silverside`: a universal release build,
  with the embedded Info.plist of its commit, signed with the hardened runtime
  before the app is signed and notarized.
- How it gets there is open: a build phase in the app (slow: `swift build -c
  release`), or `make release` copying it in before signing.
- **Install Command Line Tool…** (in the app menu, or Settings): a symbolic
  link to the helper, so that each app update brings a new CLI. Where to:
  `/usr/local/bin` needs an administrator password (`osascript … with
  administrator privileges`); `~/.local/bin` needs none, but may not be in the
  `PATH`. Offer the shell completions too. The same item can remove the link.
- `make install` stays for people who build from source.

### The DMG

- A window that opens by itself, with the app's icon, a link to
  `/Applications`, and a background picture with an arrow between them, at 1×
  and 2× (a two-image TIFF, `tiffutil -cathidpicheck`).
- Tools: `create-dmg` (Homebrew, a shell script around `hdiutil` and Finder
  scripting) or `dmgbuild` (Python, no Finder scripting, so it also runs
  headless). Either is a build tool, not shipped; mention it to the user before
  adding.
- The background is design work: the grooves and the iris band from the site
  and the About window would fit.
- Sign the DMG (`codesign`), notarize it (that covers the app inside), and
  staple it.

### `make release`

1. Archive and export with Developer ID; the CLI inside, signed.
2. Build the DMG.
3. `notarytool submit --wait`, then `stapler staple`.
4. `generate_appcast`.
5. `gh release create`, with the DMG.
6. Commit `appcast.xml` and the notes page to `docs/site`, and push `main`.

Upload before the feed changes: a feed that points at a missing file fails for
everyone who checks then.

### Testing before the first release

- A build with a lower version, pointed at a test feed (`defaults write … SUFeedURL`),
  finds the update, checks its signature, installs it, and relaunches.
- An update that arrives during a demo rip waits for the rip.
- **App Translocation:** an app opened from Downloads, not moved, runs from a
  read-only place, and Sparkle cannot replace it; Sparkle says so. Moving it
  to Applications by itself is a later nicety.
- The first public build must already have Sparkle: users of a build without
  it download the next one by hand.
