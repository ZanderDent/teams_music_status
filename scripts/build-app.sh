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

# Spotify client ID. Public by design for a PKCE desktop app, so baking it into the
# bundle is safe — but it must not be committed, so it is sourced from a git-ignored
# file rather than from the repository.
#   1. $SPOTIFY_CLIENT_ID
#   2. Config/Spotify.plist  (ClientID key)
#   3. .env                  (SPOTIFY_CLIENT_ID=...)
CLIENT_ID="${SPOTIFY_CLIENT_ID:-}"
if [ -z "$CLIENT_ID" ] && [ -f "$ROOT/Config/Spotify.plist" ]; then
  CLIENT_ID="$(/usr/libexec/PlistBuddy -c 'Print :ClientID' "$ROOT/Config/Spotify.plist" 2>/dev/null || true)"
fi
if [ -z "$CLIENT_ID" ] && [ -f "$ROOT/.env" ]; then
  CLIENT_ID="$(grep -E '^SPOTIFY_CLIENT_ID=' "$ROOT/.env" | head -1 | cut -d= -f2- | tr -d ' \r\"' || true)"
fi
if [ -z "$CLIENT_ID" ]; then
  echo "==> WARNING: no Spotify client ID found."
  echo "    The app will start, but 'Connect Spotify' will be unavailable."
  echo "    Set SPOTIFY_CLIENT_ID, or create Config/Spotify.plist with a ClientID key."
else
  echo "==> Spotify client ID found (${#CLIENT_ID} chars)"
fi

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
    <key>SpotifyClientID</key><string>$CLIENT_ID</string>
</dict>
</plist>
PLIST

# ---- signing -----------------------------------------------------------------
#
# The entitlements file must stay bare XML with no comments: codesign hands it to
# AMFI, whose parser is stricter than plutil and fails on a comment block with
# "AMFIUnserializeXML: syntax error". A silent failure here is expensive, because the
# app then runs WITHOUT com.apple.security.automation.apple-events and macOS refuses
# every Apple Event with -1743 and never prompts -- which is indistinguishable from
# the user having denied Automation access.
#
# The entitlement is needed because we sign with the hardened runtime. Without it the
# Local Spotify source and the AppleScript window-reopen fallback cannot work.
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
  codesign --force --sign "$IDENTITY" --options runtime --timestamp=none --entitlements "$ROOT/scripts/TeamsMusicStatus.entitlements" "$APP_DIR" 2>&1 | sed 's/^/    /'
else
  echo "==> no signing identity found; signing ad hoc"
  echo "    NOTE: macOS may drop the Accessibility grant on every rebuild."
  echo "    Set CODESIGN_IDENTITY to a stable certificate to avoid re-granting."
  codesign --force --sign - --entitlements "$ROOT/scripts/TeamsMusicStatus.entitlements" "$APP_DIR" 2>&1 | sed 's/^/    /'
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
