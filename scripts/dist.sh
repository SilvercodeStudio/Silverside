#!/bin/sh
# make dist: the app as others get it, in build/dist. It archives the app (as Product › Archive
# does), exports it signed with Developer ID, sends it to Apple for notarization, and staples the
# ticket to it. Then it puts the app in a disk image, Silverside-<version>.dmg (dmgbuild, with the
# window that App/DMG lays out), which it signs, notarizes, and staples too. Last, it adds the
# version to Sparkle's update feed, docs/site/appcast.xml, signed with the key in the Keychain,
# with the version's CHANGELOG entry as its notes. docs/internal/Releasing.md has the whole
# release; this script publishes nothing.
#
#   NOTARY_PROFILE  the notarytool keychain profile (default: silverside), made once with
#                   xcrun notarytool store-credentials silverside --apple-id ... --team-id ...
#   NOTARIZE=0      stop after the export and its checks: nothing goes to Apple, and no feed.
#   FEED=0          stop after the disk image: the feed stays as it is.
#   ALLOW_DIRTY=1   build with changes that are not committed (the About window then shows
#                   the commit with "-dirty"). A release is of a commit, so this is for tries,
#                   and such a build gets no feed.
set -eu

cd "$(dirname "$0")/.."
DIST=build/dist
ARCHIVE="$DIST/Silverside.xcarchive"
EXPORT="$DIST/export"
APP="$EXPORT/Silverside.app"
PROFILE="${NOTARY_PROFILE:-silverside}"
# The Keychain item of Sparkle's private key: generate_keys --account silverside made it.
KEY_ACCOUNT=silverside
FEED_FILE=docs/site/appcast.xml
RELEASES=https://github.com/SilvercodeStudio/Silverside/releases/download
# dmgbuild (MIT) and the two packages it needs, at these versions, in a Python environment of
# their own under build/tools, made at the first use.
DMGBUILD_PACKAGES="dmgbuild==1.6.7 ds_store==1.3.3 mac_alias==2.2.3"
DMGBUILD_ENV=build/tools/dmgbuild-1.6.7

DIRTY=0
if [ -n "$(git status --porcelain)" ]; then
    if [ "${ALLOW_DIRTY:-0}" != 1 ]; then
        echo "There are changes that are not committed. Commit them, or set ALLOW_DIRTY=1 for a try."
        exit 1
    fi
    DIRTY=1
fi

rm -rf "$DIST"
mkdir -p "$DIST"

echo "Archiving (Release, Apple silicon and Intel)…"
xcodebuild -workspace Silverside.xcworkspace -scheme Silverside -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -quiet archive

echo "Exporting with Developer ID…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist App/ExportOptions.plist -allowProvisioningUpdates -quiet

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

# The checks that notarization makes too, so a problem shows here first.
codesign --verify --deep --strict "$APP"
info=$(codesign -dvv "$APP" 2>&1)
echo "$info" | grep -q "Authority=Developer ID Application" || { echo "Not signed with Developer ID."; exit 1; }
echo "$info" | grep -q "flags=.*(runtime)" || { echo "No hardened runtime."; exit 1; }
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.security.automation.apple-events" ||
    { echo "No Apple Events entitlement: Add to Music would fail."; exit 1; }
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "get-task-allow" &&
    { echo "The app can be debugged (get-task-allow): notarization refuses it."; exit 1; }
# The build phase "Remove Sparkle's XPC services" removes nothing if a new Sparkle moves them.
[ ! -e "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" ] ||
    { echo "Sparkle's XPC services are still in the app: check the build phase that removes them."; exit 1; }
# The silverside command inside, for Install Command Line Tool…: signed as the app is, and this version.
HELPER="$APP/Contents/Helpers/silverside"
[ -x "$HELPER" ] || { echo "No silverside command in the app: check the build phase that puts it there."; exit 1; }
helper_info=$(codesign -dvv "$HELPER" 2>&1)
echo "$helper_info" | grep -q "Authority=Developer ID Application" && echo "$helper_info" | grep -q "flags=.*(runtime)" ||
    { echo "The silverside command is not signed with Developer ID and the hardened runtime."; exit 1; }
case "$("$HELPER" --version)" in
"$VERSION"*) ;;
*) echo "The silverside command is not version $VERSION: $("$HELPER" --version)"; exit 1 ;;
esac
for file in _silverside silverside.bash silverside.fish; do
    [ -s "$APP/Contents/Resources/Completions/$file" ] || { echo "No $file completions in the app."; exit 1; }
done
echo "Silverside $VERSION: signed with Developer ID, hardened runtime, Apple Events."

if [ "${NOTARIZE:-1}" = 0 ]; then
    echo "Not notarized (NOTARIZE=0): $APP"
    exit 0
fi

if [ ! -x "$DMGBUILD_ENV/bin/dmgbuild" ]; then
    echo "Installing dmgbuild in $DMGBUILD_ENV…"
    rm -rf "$DMGBUILD_ENV"
    python3 -m venv "$DMGBUILD_ENV"
    # shellcheck disable=SC2086 # one argument for each package
    "$DMGBUILD_ENV/bin/pip" install -q --disable-pip-version-check $DMGBUILD_PACKAGES
fi

# notarize FILE: sends the file to Apple and waits for the result. It stops the script if Apple
# does not accept it, and prints Apple's log.
notarize() {
    submitted=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --output-format json)
    id=$(echo "$submitted" | plutil -extract id raw -o - - 2>/dev/null || echo "")
    [ -n "$id" ] || { echo "The upload failed: $submitted"; exit 1; }
    echo "Submission $id. If this is stopped, xcrun notarytool wait $id --keychain-profile $PROFILE"
    result=$(xcrun notarytool wait "$id" --keychain-profile "$PROFILE" --output-format json || true)
    status=$(echo "$result" | plutil -extract status raw -o - - 2>/dev/null || echo unknown)
    if [ "$status" != Accepted ]; then
        echo "Notarization: $status."
        xcrun notarytool log "$id" --keychain-profile "$PROFILE"
        exit 1
    fi
}

# The app gets its own ticket, so that a copy dragged out of the disk image opens without a
# network connection. The upload leaves out extended attributes (--norsrc): ditto would store
# each file's com.apple.provenance as a "._" file beside it.
echo "Sending the app to Apple for notarization (usually a few minutes; a first submission can take longer)…"
UPLOAD="$DIST/upload.zip"
ditto -c -k --norsrc --keepParent "$APP" "$UPLOAD"
notarize "$UPLOAD"
rm -f "$UPLOAD"
xcrun stapler staple -q "$APP"
spctl --assess --type execute -vv "$APP" 2>&1 | grep -q "source=Notarized Developer ID" ||
    { echo "Gatekeeper does not accept the stapled app."; spctl --assess --type execute -vv "$APP"; exit 1; }

# The disk image, signed with the app's certificate. App/DMG/dmg_settings.py has its window.
echo "Making the disk image…"
DMG="$DIST/Silverside-$VERSION.dmg"
IDENTITY=$(echo "$info" | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -n 1)
"$DMGBUILD_ENV/bin/dmgbuild" -s App/DMG/dmg_settings.py -D app="$APP" Silverside "$DMG" >"$DIST/dmgbuild.log" 2>&1 ||
    { cat "$DIST/dmgbuild.log"; echo "dmgbuild failed."; exit 1; }
codesign --sign "$IDENTITY" --timestamp "$DMG"
echo "Sending the disk image to Apple for notarization…"
notarize "$DMG"
xcrun stapler staple -q "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | grep -q "source=Notarized Developer ID" ||
    { echo "Gatekeeper does not accept the disk image."; spctl --assess --type open --context context:primary-signature -vv "$DMG"; exit 1; }
# The app in the image must still be whole: a copy that follows symbolic links, or Finder
# information on the bundle, breaks its signature.
MOUNT=$(mktemp -d "$DIST/mount.XXXXXX")
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG"
image_ok=1
codesign --verify --deep --strict "$MOUNT/Silverside.app" && xcrun stapler validate -q "$MOUNT/Silverside.app" &&
    [ "$(readlink "$MOUNT/Applications")" = /Applications ] || image_ok=0
hdiutil detach -quiet "$MOUNT"
rmdir "$MOUNT"
[ "$image_ok" = 1 ] || { echo "The app in the disk image is not signed and stapled as it should be."; exit 1; }
echo "Notarized and stapled: $DMG"

# Sparkle's update feed.
if [ "${FEED:-1}" = 0 ]; then
    echo "No feed (FEED=0)."
    exit 0
fi
if [ "$DIRTY" = 1 ]; then
    echo "No feed: the build has changes that are not committed."
    exit 0
fi
case "$(grep -m 1 "^## $VERSION " CHANGELOG.md || true)" in
"## $VERSION ("[0-9]*")") ;;
*)
    echo "No feed: CHANGELOG.md needs a dated heading for this version, \"## $VERSION (YYYY-MM-DD)\"."
    exit 1
    ;;
esac

# Sparkle's tools from the package that the archive used, so that they match its framework.
build_dir=$(xcodebuild -workspace Silverside.xcworkspace -scheme Silverside -configuration Release \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *BUILD_DIR =/ {print $2; exit}')
SPARKLE_BIN="$build_dir/../../SourcePackages/artifacts/sparkle/Sparkle/bin"
[ -x "$SPARKLE_BIN/generate_appcast" ] || { echo "No Sparkle tools at $SPARKLE_BIN."; exit 1; }

# An app with another key than the Keychain's would get an item with no signature.
key=$("$SPARKLE_BIN/generate_keys" --account "$KEY_ACCOUNT" -p 2>/dev/null || true)
[ -n "$key" ] || { echo "No Sparkle key \"$KEY_ACCOUNT\" in the Keychain: see docs/internal/Releasing.md."; exit 1; }
[ "$key" = "$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist")" ] ||
    { echo "The app's SUPublicEDKey is not the public half of the Keychain's key."; exit 1; }

# generate_appcast works in a folder: the feed as it is, the new disk image, and its notes (the
# CHANGELOG entry without its heading), which it embeds as Markdown. It keeps the older items,
# whose files are not there, and signs the feed, as the app's Info.plist asks.
FEED_DIR="$DIST/feed"
mkdir -p "$FEED_DIR"
cp "$DMG" "$FEED_DIR/"
NOTES="$FEED_DIR/Silverside-$VERSION.md"
awk -v heading="## $VERSION " 'index($0, heading) == 1 {on = 1; next} on && /^## / {exit} on' CHANGELOG.md >"$NOTES"
if [ -f "$FEED_FILE" ]; then cp "$FEED_FILE" "$FEED_DIR/appcast.xml"; fi
echo "Signing the feed (the Keychain may ask to let generate_appcast use the key)…"
"$SPARKLE_BIN/generate_appcast" --account "$KEY_ACCOUNT" --maximum-deltas 0 --embed-release-notes \
    --download-url-prefix "$RELEASES/$VERSION/" --link https://silverside.app "$FEED_DIR"
grep "$RELEASES/$VERSION/Silverside-$VERSION.dmg\"" "$FEED_DIR/appcast.xml" | grep -q "sparkle:edSignature=" ||
    { echo "The feed's item for $VERSION has no signature: $FEED_DIR/appcast.xml"; exit 1; }
cp "$FEED_DIR/appcast.xml" "$FEED_FILE"
echo "The feed lists $VERSION: $FEED_FILE. Publish in this order, so that the feed never names a missing file:"
echo "  git tag -a $VERSION -m $VERSION && git push origin $VERSION"
echo "  gh release create $VERSION $DMG --title \"Silverside $VERSION\" --notes-file $NOTES"
echo "  Commit $FEED_FILE alone, and push main: GitHub Pages publishes the feed."
