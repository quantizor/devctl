#!/bin/zsh
# Assembles devctl.app from the SPM-built DevCtlApp binary. No Xcode: the bundle
# is directory layout + Info.plist + signature. Ad-hoc signed by default; pass a
# Developer ID identity as $1 to upgrade.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${1:--}"
CONFIG="${2:-release}"
BINARY="$ROOT/.build/$CONFIG/DevCtlApp"
APP="$ROOT/devctl.app"

[[ -x "$BINARY" ]] || { echo "make-app-bundle: build first (missing $BINARY)" >&2; exit 1 }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/devctl-app"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>devctl-app</string>
    <key>CFBundleIdentifier</key>
    <string>dev.quantizor.devctl.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>devctl</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$("$ROOT/.build/$CONFIG/devctl" --version 2>/dev/null || echo 0.1.0)</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>dev.quantizor.devctl.url</string>
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
codesign --force --sign "$IDENTITY" "$APP"
echo "assembled $APP (signed: $IDENTITY)"
