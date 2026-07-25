#!/bin/zsh
# Builds the devctl DMG from the assembled (and signed) devctl.app.
# Usage: scripts/make-dmg.sh [SIGN_IDENTITY]
#
# The image holds the app alone: no /Applications symlink. Setup happens inside
# the app (it copies itself to /Applications after an explicit confirm), so a
# drag target would be a second, conflicting way to install. The window
# background says to double-click instead.
#
# Finder styling needs a GUI session. Without one the AppleScript pass is skipped
# and the image still ships, just unstyled: plain icon view, background file
# present but unused. Set DEVCTL_DMG_REQUIRE_LAYOUT=1 to make that a hard error,
# so a release build never quietly loses the instructions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${1:--}"
APP="$ROOT/devctl.app"
DIST="$ROOT/dist"
STAGE="$DIST/dmg-stage"
VOLUME_NAME="devctl"

[[ -d "$APP" ]] || { echo "make-dmg: run make app first (missing $APP)" >&2; exit 1 }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
DMG="$DIST/devctl-${VERSION}.dmg"
RW_DMG="$DIST/.devctl-${VERSION}.rw.dmg"

rm -rf "$STAGE"
mkdir -p "$STAGE/.background" "$DIST"
ditto "$APP" "$STAGE/devctl.app"

echo "rendering background..."
swift "$ROOT/scripts/make-dmg-background.swift" "$STAGE/.background"
tiffutil -cathidpicheck \
  "$STAGE/.background/background.png" \
  "$STAGE/.background/background@2x.png" \
  -out "$STAGE/.background/background.tiff" > /dev/null
rm -f "$STAGE/.background/background.png" "$STAGE/.background/background@2x.png"

rm -f "$DMG" "$RW_DMG"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDRW \
  "$RW_DMG" > /dev/null

# Mount under /Volumes and read the name back: Finder resolves the window by
# volume name, and a stale devctl mount makes this one "devctl 1". Custom
# -mountpoint or -nobrowse both break the AppleScript lookup.
MOUNT_POINT="$(hdiutil attach "$RW_DMG" -noverify -noautoopen | awk -F'\t' '/\/Volumes\// { print $NF }' | tail -1)"
[[ -n "$MOUNT_POINT" ]] || { echo "make-dmg: could not mount $RW_DMG" >&2; exit 1 }
MOUNTED_NAME="$(basename "$MOUNT_POINT")"
abort_cleanup() {
  hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
  rm -f "$RW_DMG"
  rm -rf "$STAGE"
}
trap abort_cleanup EXIT

LAYOUT_LOG="$(mktemp "${TMPDIR:-/tmp}/devctl-dmg-layout.XXXXXX")"
if osascript - "$MOUNTED_NAME" > "$LAYOUT_LOG" 2>&1 <<'APPLESCRIPT'
on run argv
  set volumeName to item 1 of argv
  tell application "Finder"
    tell disk volumeName
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {200, 120, 760, 500}
      set viewOptions to the icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 128
      set text size of viewOptions to 12
      set background picture of viewOptions to file ".background:background.tiff"
      set position of item "devctl.app" of container window to {280, 125}
      update without registering applications
      delay 1
      close
    end tell
  end tell
end run
APPLESCRIPT
then
  echo "applied Finder window layout"
  rm -f "$LAYOUT_LOG"
elif [[ "${DEVCTL_DMG_REQUIRE_LAYOUT:-0}" == "1" ]]; then
  echo "make-dmg: Finder window layout failed and DEVCTL_DMG_REQUIRE_LAYOUT=1" >&2
  cat "$LAYOUT_LOG" >&2
  echo "make-dmg: run from a logged-in GUI session, grant the terminal Automation access for Finder, and check that no other volume is named $VOLUME_NAME" >&2
  exit 1
else
  echo "note: skipped Finder layout; the image ships unstyled. Reason:"
  sed 's/^/  /' "$LAYOUT_LOG"
  rm -f "$LAYOUT_LOG"
fi

rm -rf "$MOUNT_POINT/.fseventsd"
sync
hdiutil detach "$MOUNT_POINT" -quiet
trap - EXIT

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" > /dev/null
rm -f "$RW_DMG"
rm -rf "$STAGE"

if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --sign "$IDENTITY" "$DMG"
  echo "signed DMG with $IDENTITY"
fi

echo "wrote $DMG"
