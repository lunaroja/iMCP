#!/bin/bash
# Xcode cannot select a Catalyst variant for a native macOS target dependency.
set -euo pipefail

: "${SRCROOT:?Run this script from the iMCP Xcode build phase.}"
: "${TARGET_BUILD_DIR:?Missing Xcode product directory.}"
: "${WRAPPER_NAME:?Missing Xcode app wrapper name.}"
: "${CONFIGURATION:?Missing Xcode configuration.}"
: "${PROJECT_TEMP_DIR:?Missing Xcode intermediates directory.}"

# Developer ID builds can't carry the HomeKit entitlement,
# so the default release configuration leaves the helper out.
# A development-signed build can set EMBED_HOME_HELPER=YES.
if [[ "${EMBED_HOME_HELPER:-YES}" != YES ]]; then
    echo "Skipping iMCP Helper (EMBED_HOME_HELPER=${EMBED_HOME_HELPER})."
    # Remove a helper left by an earlier build in the same directory.
    rm -rf "$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Helpers/iMCP Helper.app"
    rm -rf "$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Helpers/iMCP Home.app"
    rm -f "$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Library/LaunchAgents/$PRODUCT_BUNDLE_IDENTIFIER.home-helper.plist"
    exit 0
fi

helper_derived_data="$PROJECT_TEMP_DIR/HelperDerivedData"
helper_signing="${HELPER_CODE_SIGNING_ALLOWED:-YES}"
helper_options=(
    INFOPLIST_FILE=Scripts/HomeHelper-XPC-Info.plist
    HOME_HELPER_HOST_BUNDLE_IDENTIFIER="$PRODUCT_BUNDLE_IDENTIFIER"
)
if [[ "$helper_signing" == YES ]]; then
    helper_options+=(-allowProvisioningUpdates)
fi
if [[ -n "${HOME_HELPER_DEVELOPMENT_TEAM:-}" ]]; then
    helper_options+=(DEVELOPMENT_TEAM="$HOME_HELPER_DEVELOPMENT_TEAM")
fi
if [[ -n "${HOME_HELPER_BUNDLE_IDENTIFIER:-}" ]]; then
    helper_options+=(HELPER_BUNDLE_IDENTIFIER="$HOME_HELPER_BUNDLE_IDENTIFIER")
fi

# Keep the nested build's environment, products, and build database separate.
# Inherited Xcode settings otherwise rename package products after the native app.
env -i PATH="$PATH" HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" \
    TMPDIR="${TMPDIR:-/tmp}" DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}" \
    xcodebuild -quiet -project "$SRCROOT/iMCP.xcodeproj" \
    -scheme "iMCP Helper" -configuration "$CONFIGURATION" \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath "$helper_derived_data" \
    "${helper_options[@]}" \
    CODE_SIGNING_ALLOWED="$helper_signing" CODE_SIGNING_REQUIRED="$helper_signing" \
    build

helper_product="$helper_derived_data/Build/Products/$CONFIGURATION-maccatalyst/iMCP Helper.app"
rm -rf "$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Helpers/iMCP Helper.app"
helper_destination="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Helpers/iMCP Home.app"
if [[ ! -d "$helper_product/Contents/MacOS" ]]; then
    echo 'error: The iMCP Helper build did not produce a Catalyst app.' >&2
    exit 1
fi
mkdir -p "$(dirname "$helper_destination")"
# ditto preserves the helper's development signature.
# Remove stale files if the nested app's contents changed between builds.
rm -rf "$helper_destination"
ditto "$helper_product" "$helper_destination"


agent_dir="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Library/LaunchAgents"
mkdir -p "$agent_dir"
/usr/bin/sed "s/__HOST__/$PRODUCT_BUNDLE_IDENTIFIER/g" "$SRCROOT/Scripts/home-helper.launchd.plist.in" \
    > "$agent_dir/$PRODUCT_BUNDLE_IDENTIFIER.home-helper.plist"
