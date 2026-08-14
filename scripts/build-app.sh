#!/bin/bash
#
# build-app.sh — assemble and sign TeamsMusicStatus.app from the SwiftPM build.
#
# SwiftPM produces a bare executable; macOS needs a bundle for LSUIElement, for
# SMAppService launch-at-login, and — most importantly — so TCC can attribute the
# Accessibility grant to a stable identity.
#
#   ./scripts/build-app.sh                 debug build
#   ./scripts/build-app.sh --release       optimised build
#   ./scripts/build-app.sh --run           build, then launch
#
# Signing: uses the first "Apple Development" identity found, or $CODESIGN_IDENTITY.
# A STABLE identity matters — re-signing ad hoc changes the code requirement and macOS
# silently drops the Accessibility permission, forcing you to re-grant it every build.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

CONFIG="debug"
RUN=0
for arg in "$@"; do
  case "$arg" in
    --release) CONFIG="release" ;;
    --run) RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

APP_NAME="TeamsMusicStatus"
BUNDLE_ID="com.zanderdent.TeamsMusicStatus"
VERSION="0.1.0"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product "$APP_NAME"
BINARY="$(swift build -c "$CONFIG" --product "$APP_NAME" --show-bin-path)/$APP_NAME"
[ -x "$BINARY" ] || { echo "build produced no binary at $BINARY" >&2; exit 1; }

APP_DIR="$ROOT/build/$APP_NAME.app"
echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Teams Music Status</string>
    <key>CFBundleDisplayName</key><string>Teams Music Status</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>

    <!-- Menu-bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key><true/>

    <!-- Shown in the macOS Automation consent prompt, which the Local Spotify
         source triggers. Users deserve to know why an app wants this. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Teams Music Status reads the currently playing track from the Spotify app on this Mac, and can reopen a closed Microsoft Teams window so your status can be updated.</string>

    <!-- Spotify client IDs are public by design for PKCE desktop apps. Overridden by
         the SPOTIFY_CLIENT_ID environment variable during development. -->
    <key>SpotifyClientID</key><string>${SPOTIFY_CLIENT_ID:-}</string>
</dict>
</plist>
PLIST

# ---- signing -----------------------------------------------------------------
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  # Select by SHA-1 hash, not by name: the same certificate name can appear in more
  # than one keychain, and codesign then refuses with "ambiguous". The hash also keeps
  # the developer's name and email out of the build log.
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 'Apple Development' | awk '{print $2}' || true)"
fi

if [ -n "$IDENTITY" ]; then
  echo "==> codesign with identity ${IDENTITY:0:8}…"
  codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$APP_DIR" 2>&1 | sed 's/^/    /'
else
  echo "==> no signing identity found; signing ad hoc"
  echo "    NOTE: macOS may drop the Accessibility grant on every rebuild."
  echo "    Set CODESIGN_IDENTITY to a stable certificate to avoid re-granting."
  codesign --force --sign - "$APP_DIR" 2>&1 | sed 's/^/    /'
fi

codesign --verify --verbose=1 "$APP_DIR" 2>&1 | sed 's/^/    /'
echo "==> built $APP_DIR"

if [ "$RUN" = "1" ]; then
  echo "==> launching"
  # Kill a previous instance so the new binary is the one holding the menu bar item.
  pkill -f "$APP_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  sleep 0.5
  open "$APP_DIR"
fi
