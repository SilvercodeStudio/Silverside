#!/bin/sh
# make dist: the app as others get it, in build/dist. It archives the app (as Product › Archive
# does), exports it signed with Developer ID, sends it to Apple for notarization, staples the
# ticket to it, and zips it as Silverside-<version>.zip.
#
#   NOTARY_PROFILE  the notarytool keychain profile (default: silverside), made once with
#                   xcrun notarytool store-credentials silverside --apple-id ... --team-id ...
#   NOTARIZE=0      stop after the export and its checks: nothing goes to Apple.
#   ALLOW_DIRTY=1   build with changes that are not committed (the About window then shows
#                   the commit with "-dirty"). A release is of a commit, so this is for tries.
set -eu

cd "$(dirname "$0")/.."
DIST=build/dist
ARCHIVE="$DIST/Silverside.xcarchive"
EXPORT="$DIST/export"
APP="$EXPORT/Silverside.app"
PROFILE="${NOTARY_PROFILE:-silverside}"

if [ "${ALLOW_DIRTY:-0}" != 1 ] && [ -n "$(git status --porcelain)" ]; then
    echo "There are changes that are not committed. Commit them, or set ALLOW_DIRTY=1 for a try."
    exit 1
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
echo "Silverside $VERSION: signed with Developer ID, hardened runtime, Apple Events."

if [ "${NOTARIZE:-1}" = 0 ]; then
    echo "Not notarized (NOTARIZE=0): $APP"
    exit 0
fi

# The zips leave out extended attributes (--norsrc). Without it, ditto stores each file's
# com.apple.provenance as a "._" file beside it, and a tool other than ditto or Archive Utility
# (unzip, for one) unpacks those as files in the bundle, which breaks its seal.
echo "Sending to Apple for notarization (usually a few minutes; a first submission can take longer)…"
UPLOAD="$DIST/upload.zip"
ditto -c -k --norsrc --keepParent "$APP" "$UPLOAD"
submitted=$(xcrun notarytool submit "$UPLOAD" --keychain-profile "$PROFILE" --output-format json)
rm -f "$UPLOAD"
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

xcrun stapler staple -q "$APP"
spctl --assess --type execute -vv "$APP" 2>&1 | grep -q "source=Notarized Developer ID" ||
    { echo "Gatekeeper does not accept the stapled app."; spctl --assess --type execute -vv "$APP"; exit 1; }

ZIP="$DIST/Silverside-$VERSION.zip"
ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
zipinfo -1 "$ZIP" | grep -q '/\._' && { echo "The zip has AppleDouble files: unzip would break the seal."; exit 1; }
echo "Notarized and stapled: $ZIP"
