#!/usr/bin/env bash
#
# Build, install, and launch HermesMobile on a connected physical device.
# Requires a development team (automatic signing) and a trusted, paired device.
#
# Usage:
#   DEVELOPMENT_TEAM=<your 10-char team id> scripts/run-device.sh
# Env:
#   DEVICE_UDID               optional hardware UDID, required if multiple devices qualify
#   DEVICE_ID                 optional hardware UDID or CoreDevice identifier
#   HERMES_DEFAULT_SERVER_URL optional server preset for the Debug build
# Notes:
#   - Find your team id under the Apple Distribution/Development cert, e.g. 7V99GYC5W7.
#   - The team is baked into the project at generate time, so this regenerates.
#   - Untested in CI here (no device) — drives `xcodebuild` + `devicectl`.
#
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SCHEME="HermesMobile"
WORKSPACE="HermesMobile.xcworkspace"
BUNDLE_ID="com.taquitos.HermesMobile"

: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM=<your 10-char Apple team id> and re-run}"

# CoreDevice identifiers and hardware UDIDs have different formats. Xcode needs
# the hardware UDID; select from structured fields instead of the display table.
DEVICE_LIST="$(mktemp -t hermes-mobile-devices)"
trap 'rm -f "$DEVICE_LIST"' EXIT
xcrun devicectl list devices --json-output "$DEVICE_LIST" >/dev/null
SELECTED_DEVICE_UDID="$(/usr/bin/python3 scripts/select_device.py "$DEVICE_LIST")"
rm -f "$DEVICE_LIST"
echo "▸ Device: $SELECTED_DEVICE_UDID"

echo "▸ Generating project with team $DEVELOPMENT_TEAM"
# Tuist only forwards TUIST_-prefixed env vars to the manifest, so translate.
TUIST_DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  TUIST_SERVER_URL="${HERMES_DEFAULT_SERVER_URL:-}" tuist generate --no-open

echo "▸ Building (automatic signing)…"
xcodebuild build \
  -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration Debug \
  -destination "id=$SELECTED_DEVICE_UDID" \
  -allowProvisioningUpdates \
  -quiet

APP_PATH="$(
  xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration Debug \
    -destination "id=$SELECTED_DEVICE_UDID" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ TARGET_BUILD_DIR =/{d=$2} / FULL_PRODUCT_NAME =/{n=$2} END{print d"/"n}'
)"

echo "▸ Installing $(basename "$APP_PATH")"
xcrun devicectl device install app --device "$SELECTED_DEVICE_UDID" "$APP_PATH"
echo "▸ Launching $BUNDLE_ID"
xcrun devicectl device process launch --device "$SELECTED_DEVICE_UDID" "$BUNDLE_ID"
echo "✓ Running on device"
