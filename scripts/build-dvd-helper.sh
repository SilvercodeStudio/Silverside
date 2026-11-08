#!/bin/sh
# Xcode app build phase: build the original helper for the app's architectures,
# then sign only that executable with the external-library entitlement.
set -eu
project_root="$SRCROOT/.."
helper_build="$DERIVED_FILE_DIR/DVDHelperBuild"
helper_destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
case "$CONFIGURATION" in
    Debug) helper_configuration=debug ;;
    *) helper_configuration=release ;;
esac
set --
for architecture in $ARCHS; do set -- "$@" --arch "$architecture"; done
/usr/bin/env -u SDKROOT /usr/bin/xcrun swift build --package-path "$project_root/SilversideKit" \
    --scratch-path "$helper_build" --configuration "$helper_configuration" "$@" --product silverside-dvd-helper
helper_bin=$(/usr/bin/env -u SDKROOT /usr/bin/xcrun swift build --package-path "$project_root/SilversideKit" \
    --scratch-path "$helper_build" --configuration "$helper_configuration" "$@" --show-bin-path)
/bin/mkdir -p "$helper_destination"
/usr/bin/install -m 755 "$helper_bin/silverside-dvd-helper" "$helper_destination/silverside-dvd-helper"
helper_identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
/usr/bin/codesign --force --sign "$helper_identity" --options runtime \
    --entitlements "$project_root/SilversideKit/Sources/silverside-dvd-helper/entitlements.plist" \
    "$helper_destination/silverside-dvd-helper"
