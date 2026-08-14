#!/bin/bash
#
# uninstall.sh — remove every trace of Teams Music Status from this Mac.
#
#   ./scripts/uninstall.sh              remove app, preferences, tokens, permissions
#   ./scripts/uninstall.sh --keep-app   leave the built .app in place (for re-testing
#                                       first-run onboarding without rebuilding)
#
# Removes:
#   * the running process and the .app bundle (build/ and /Applications)
#   * the launch-at-login registration
#   * preferences in UserDefaults
#   * the Spotify OAuth tokens in the Keychain
#   * the Accessibility and Automation permission grants
#   * saved window state and caches
#
# It does NOT touch your Microsoft Teams status. If the app left one behind, clear it in
# Teams, or run `swift run tmsctl set "your status"` first.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

APP_NAME="TeamsMusicStatus"
BUNDLE_ID="com.zanderdent.TeamsMusicStatus"
KEYCHAIN_SERVICE="$BUNDLE_ID.spotify"

KEEP_APP=0
[ "${1:-}" = "--keep-app" ] && KEEP_APP=1

step() { printf '\033[1m==>\033[0m %s\n' "$1"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '    \033[2m·\033[0m %s\n' "$1"; }

step "Quitting $APP_NAME"
if pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1
  sleep 1
  pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1
  ok "stopped"
else
  skip "not running"
fi

step "Removing the launch-at-login registration"
# SMAppService keeps its record keyed on the bundle; unregistering needs the app itself,
# so the best we can do from a script is clear the legacy job label if one exists.
launchctl bootout "gui/$(id -u)/$BUNDLE_ID" >/dev/null 2>&1 \
  && ok "login item removed" || skip "no login item registered"

step "Revoking permissions"
# tccutil resolves the bundle id through LaunchServices, which does not know about an
# app that has only ever been built and never launched. Register it first, or the reset
# fails with "No such bundle identifier" and leaves the grants in place.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for candidate in "$ROOT/build/$APP_NAME.app" "/Applications/$APP_NAME.app"; do
  [ -d "$candidate" ] && "$LSREGISTER" -f "$candidate" >/dev/null 2>&1
done

# MUST happen before the bundle is deleted: tccutil resolves the bundle id through
# LaunchServices, and once the .app is gone it fails with "No such bundle identifier"
# and silently leaves the grants behind. That would make the next install look like a
# first run while actually still holding Accessibility access.
tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 \
  && ok "Accessibility grant reset" || skip "no Accessibility grant to reset"
tccutil reset AppleEvents "$BUNDLE_ID" >/dev/null 2>&1 \
  && ok "Automation grant reset" || skip "no Automation grant to reset"

if [ "$KEEP_APP" = "0" ]; then
  step "Removing the application bundle"
  for path in "$ROOT/build/$APP_NAME.app" "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
    if [ -d "$path" ]; then rm -rf "$path" && ok "removed $path"; fi
  done
else
  step "Keeping the application bundle (--keep-app)"
  skip "$ROOT/build/$APP_NAME.app left in place"
fi

step "Removing preferences"
if defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 && ok "UserDefaults cleared"
else
  skip "no preferences found"
fi
# cfprefsd caches aggressively; without this a relaunch can still see the old values.
killall cfprefsd >/dev/null 2>&1 || true
rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist" 2>/dev/null

step "Removing Spotify tokens from the Keychain"
if security find-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
  security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 && ok "tokens deleted"
else
  skip "no tokens stored"
fi

step "Removing caches and saved state"
for path in \
  "$HOME/Library/Caches/$BUNDLE_ID" \
  "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
  "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" \
  "$HOME/Library/WebKit/$BUNDLE_ID"
do
  if [ -e "$path" ]; then rm -rf "$path" && ok "removed $(basename "$path")"; fi
done

echo
printf '\033[1mDone.\033[0m Teams Music Status has been removed from this Mac.\n'
echo "Rebuild with ./scripts/build-app.sh --run to start again from a clean first run."
