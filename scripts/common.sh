#!/bin/bash
#
# common.sh — configuration shared by build-app.sh and release.sh.
#
# Sourced, never executed. Everything that both scripts need to agree on lives here so
# there is exactly one place to change it: version, bundle identity, and where the
# Spotify client ID comes from.

# Resolve the repository root from this file's location, so the scripts work regardless
# of the caller's working directory.
TMS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TMS_SCRIPT_DIR/.." && pwd)"

# ── Identity ─────────────────────────────────────────────────────────────────
# The executable keeps the compact name; the *bundle* uses the display name for
# release, because that is what a user sees in Applications and the Dock-less menu bar.
EXECUTABLE_NAME="TeamsMusicStatus"
DISPLAY_NAME="Teams Music Status"
BUNDLE_ID="com.zanderdent.TeamsMusicStatus"

# Development builds keep the compact bundle name so a working local install is not
# disturbed by release packaging.
DEV_APP_NAME="TeamsMusicStatus.app"
RELEASE_APP_NAME="Teams Music Status.app"

# Deployment target. Must match `platforms:` in Package.swift — release.sh asserts it.
MIN_MACOS="14.0"

ENTITLEMENTS="$ROOT/scripts/TeamsMusicStatus.entitlements"
ICON_ICNS="$ROOT/Assets/AppIcon/AppIcon.icns"

# ── Version ──────────────────────────────────────────────────────────────────
# Single source of truth: the VERSION file. Nothing else may hardcode these.
read_version() {
  local file="$ROOT/VERSION"
  [ -f "$file" ] || { echo "VERSION file missing at $file" >&2; return 1; }
  MARKETING_VERSION="$(grep -E '^MARKETING_VERSION=' "$file" | head -1 | cut -d= -f2- | tr -d ' \r')"
  BUILD_NUMBER="$(grep -E '^BUILD_NUMBER=' "$file" | head -1 | cut -d= -f2- | tr -d ' \r')"
  if [ -z "${MARKETING_VERSION:-}" ] || [ -z "${BUILD_NUMBER:-}" ]; then
    echo "VERSION must define MARKETING_VERSION and BUILD_NUMBER" >&2
    return 1
  fi
  export MARKETING_VERSION BUILD_NUMBER
}

# ── Spotify client ID ────────────────────────────────────────────────────────
# Public by design for an OAuth PKCE desktop app, so embedding it in the bundle is
# safe and expected. It is still sourced from git-ignored files rather than the
# repository, so a fork does not inherit someone else's registration and the repo can
# be public without shipping unrelated configuration.
#
# There is deliberately NO handling of a client secret anywhere: PKCE does not use one,
# and a shipped secret would be extractable from the bundle in seconds.
#
# Resolution order:
#   1. $SPOTIFY_CLIENT_ID
#   2. Config/Spotify.plist   (ClientID key)      — git-ignored
#   3. .env                   (SPOTIFY_CLIENT_ID=…) — git-ignored
resolve_client_id() {
  CLIENT_ID="${SPOTIFY_CLIENT_ID:-}"
  if [ -z "$CLIENT_ID" ] && [ -f "$ROOT/Config/Spotify.plist" ]; then
    CLIENT_ID="$(/usr/libexec/PlistBuddy -c 'Print :ClientID' "$ROOT/Config/Spotify.plist" 2>/dev/null || true)"
  fi
  if [ -z "$CLIENT_ID" ] && [ -f "$ROOT/.env" ]; then
    CLIENT_ID="$(grep -E '^SPOTIFY_CLIENT_ID=' "$ROOT/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' \r"' || true)"
  fi
  export CLIENT_ID
}

# ── Info.plist ───────────────────────────────────────────────────────────────
# Written by both scripts so the development and release bundles cannot drift apart in
# ways that change behaviour (LSUIElement in particular).
write_info_plist() {
  local plist="$1"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$MARKETING_VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSHumanReadableCopyright</key><string>MIT licensed. Not affiliated with Microsoft or Spotify.</string>

    <!-- Menu-bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key><true/>

    <!-- Shown in the macOS Automation consent prompt, which the Local Spotify source
         triggers. Users deserve to know why an app wants this. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Teams Music Status reads the currently playing track from the Spotify app on this Mac, and can reopen a closed Microsoft Teams window so your status can be updated.</string>

    <!-- Spotify client IDs are public by design for PKCE desktop apps. -->
    <key>SpotifyClientID</key><string>$CLIENT_ID</string>
</dict>
</plist>
PLIST
}
