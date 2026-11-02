# Optional DVD helper

This executable loads the user's Homebrew `libdvdread` (and its transitive
`libdvdcss`) with `dlopen`/`dlsym`. It uses opaque public handles, and does not
link or ship either library, encryption code, or keys. It has no Homebrew
build dependency. Plain AUDIO_TS directories use ordinary filesystem reads.

`make cli`, `make release` and `make install` build/install it alongside
`silverside`. `SILVERSIDE_DVD_HELPER` overrides discovery in the CLI;
`SILVERSIDE_DVDREAD` overrides the absolute library path (`none` disables it).
The helper never installs dependencies or escalates privileges.

Internal protocol v1:

- `capabilities`: library availability and supported operations as JSON.
- `inventory SOURCE WORKDIR`: navigation JSON and bounded program samples in
  an existing private work directory. JSON goes to stdout; diagnostics to stderr.
- `read SOURCE SET FIRST COUNT OUTPUT FINGERPRINT protocol-1`: an exclusive new
  AOB file, addressed in 2048-byte sectors within the title set. Rechecks the
  navigation fingerprint before reading and returns a JSON completion marker.

The CLI owns cancellation, the work directory, and the report. Reads are bounded
and the helper has a 120-second watchdog around physical library operations.
The parent also bounds process runtime and kills an unresponsive cancelled child.

For Developer ID distribution, sign **only this helper** with
`entitlements.plist` and the hardened runtime. Sign the main CLI/app with its
normal entitlements. Example after a universal `make release`:

```sh
codesign --force --options runtime --timestamp \
  --entitlements SilversideKit/Sources/silverside-dvd-helper/entitlements.plist \
  --sign 'Developer ID Application: YOUR IDENTITY' \
  SilversideKit/.build/out/Products/Release/silverside-dvd-helper
codesign --force --options runtime --timestamp \
  --sign 'Developer ID Application: YOUR IDENTITY' \
  SilversideKit/.build/out/Products/Release/silverside
```

This supplies the helper-only library-validation exception. It is not a
notarization result. Developer ID signing, notarization, clean-machine execution,
Intel execution and macOS 15 execution remain release checks. The initial CLI
change does not add the helper or this entitlement to the GUI app bundle.
