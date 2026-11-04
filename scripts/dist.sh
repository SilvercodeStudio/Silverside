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

echo "Sending to Apple for notarization (usually a few minutes)…"
UPLOAD="$DIST/upload.zip"
ditto -c -k --keepParent "$APP" "$UPLOAD"
result=$(xcrun notarytool submit "$UPLOAD" --keychain-profile "$PROFILE" --wait --output-format json)
rm -f "$UPLOAD"
status=$(echo "$result" | plutil -extract status raw -o - - 2>/dev/null || echo unknown)
if [ "$status" != Accepted ]; then
    id=$(echo "$result" | plutil -extract id raw -o - - 2>/dev/null || echo "")
    echo "Notarization: $status."
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE"
    exit 1
fi

xcrun stapler staple -q "$APP"
spctl --assess --type execute -vv "$APP" 2>&1 | grep -q "source=Notarized Developer ID" ||
    { echo "Gatekeeper does not accept the stapled app."; spctl --assess --type execute -vv "$APP"; exit 1; }

ZIP="$DIST/Silverside-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Notarized and stapled: $ZIP"
