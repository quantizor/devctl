#!/bin/zsh
# Assembles devctl.app from the SPM-built products. No Xcode: the bundle is
# directory layout + Info.plist + signature. Contents/Resources carries the CLI
# (and a Resources copy of the daemon for setup); Contents/Helpers/devctld is the
# SMAppService BundleProgram target; Contents/Library/LaunchAgents holds the
# in-bundle agent plist. Ad-hoc signed by default; pass a Developer ID identity
# as $1 to upgrade (notarization needs it).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${1:--}"
CONFIG="${2:-release}"
BUILD="$ROOT/.build/$CONFIG"
APP_BINARY="$BUILD/DevCtlApp"
CLI_BINARY="$BUILD/devctl"
DAEMON_BINARY="$BUILD/devctld"
APP="$ROOT/devctl.app"
LABEL="dev.quantizor.devctl"

[[ -x "$APP_BINARY" ]] || { echo "make-app-bundle: build first (missing $APP_BINARY)" >&2; exit 1 }
[[ -x "$CLI_BINARY" ]] || { echo "make-app-bundle: build first (missing $CLI_BINARY)" >&2; exit 1 }
[[ -x "$DAEMON_BINARY" ]] || { echo "make-app-bundle: build first (missing $DAEMON_BINARY)" >&2; exit 1 }

ICON_ICNS="$ROOT/Resources/AppIcon.icns"
[[ -f "$ICON_ICNS" ]] || { echo "make-app-bundle: missing $ICON_ICNS" >&2; exit 1 }

rm -rf "$APP"
mkdir -p \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Resources" \
  "$APP/Contents/Helpers" \
  "$APP/Contents/Library/LaunchAgents"
cp "$APP_BINARY" "$APP/Contents/MacOS/devctl-app"
cp "$CLI_BINARY" "$APP/Contents/Resources/devctl"
cp "$DAEMON_BINARY" "$APP/Contents/Resources/devctld"
cp "$DAEMON_BINARY" "$APP/Contents/Helpers/devctld"
cp "$ICON_ICNS" "$APP/Contents/Resources/AppIcon.icns"
chmod 755 \
  "$APP/Contents/MacOS/devctl-app" \
  "$APP/Contents/Resources/devctl" \
  "$APP/Contents/Resources/devctld" \
  "$APP/Contents/Helpers/devctld"

# Sealed in-bundle agent: BundleProgram (SMAppService-only), static PATH floor.
# Dynamic login PATH lives in Application Support/agent.path (daemon applies it).
# Stdio redirects omitted: per-user paths cannot be baked into a notarized plist;
# the daemon writes its own daemon.log after start.
cat > "$APP/Contents/Library/LaunchAgents/${LABEL}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>BundleProgram</key>
	<string>Contents/Helpers/devctld</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
	</dict>
	<key>ExitTimeOut</key>
	<integer>60</integer>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
PLIST

VERSION="$("$CLI_BINARY" --version 2>/dev/null || echo 0.1.0)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>quantizor/devctl</string>
    <key>CFBundleExecutable</key>
    <string>devctl-app</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>dev.quantizor.devctl.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>devctl</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>dev.quantizor.devctl.url</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>devctl</string>
            </array>
        </dict>
    </array>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "APPL????" > "$APP/Contents/PkgInfo"

sign() {
  local target="$1"
  if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign "$IDENTITY" "$target"
  else
    # Hardened runtime is required for Developer ID notarization.
    codesign --force --options runtime --sign "$IDENTITY" "$target"
  fi
}

# Nested Mach-Os first, then the outer bundle (Gatekeeper walks inward).
sign "$APP/Contents/Resources/devctl"
sign "$APP/Contents/Resources/devctld"
sign "$APP/Contents/Helpers/devctld"
sign "$APP/Contents/MacOS/devctl-app"
sign "$APP"
echo "assembled $APP (signed: $IDENTITY; Helpers/devctld + LaunchAgents + Resources)"
