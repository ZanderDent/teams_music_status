#!/usr/bin/env bash
#
# Onboarding acceptance for v1.0.1, to be run on the machine under test.
#
# Two scenarios, and the second is the one that matters. The defects this release fixes do
# NOT reproduce on a wiped profile: a fresh install has always behaved correctly. They only
# appear on a profile carrying state left by 1.0.0, so an acceptance run that begins by
# resetting preferences will pass while the bug is still shipping.
#
#   Usage:  ./scripts/acceptance-onboarding.sh fresh
#           ./scripts/acceptance-onboarding.sh upgrade
#           ./scripts/acceptance-onboarding.sh check
#
# `fresh` and `upgrade` put the machine into a known state and launch the app. `check`
# reads back what the app decided, so most of this is verifiable from output rather than by
# watching the screen. The parts a human must judge are printed as explicit prompts —
# clicking Allow on a macOS consent dialog cannot be automated, by design.

set -euo pipefail

BUNDLE_ID="com.zanderdent.TeamsMusicStatus"
APP="/Applications/Teams Music Status.app"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
ask()  { printf '  \033[33m?\033[0m %s\n' "$*"; }

quit_app() {
  osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || true
  for _ in $(seq 1 12); do
    pgrep -f "Teams Music Status.app/Contents/MacOS" >/dev/null || return 0
    sleep 1
  done
  pkill -f "Teams Music Status.app/Contents/MacOS" 2>/dev/null || true
}

require_app() {
  [ -d "$APP" ] || { bad "no app at $APP — install the DMG first"; exit 1; }
}

show_state() {
  echo "    hasCompletedOnboarding : $(defaults read "$BUNDLE_ID" hasCompletedOnboarding 2>/dev/null || echo '<unset>')"
  echo "    sourceKind             : $(defaults read "$BUNDLE_ID" sourceKind 2>/dev/null || echo '<unset>')"
  echo "    sourceChosenExplicitly : $(defaults read "$BUNDLE_ID" sourceChosenExplicitly 2>/dev/null || echo '<unset>')"
}

case "${1:-}" in

fresh)
  require_app
  bold "Scenario A — a genuinely new user"
  quit_app
  defaults delete "$BUNDLE_ID" 2>/dev/null || true
  killall cfprefsd 2>/dev/null || true
  # Revoke both grants so the prompts are actually exercised rather than inherited.
  tccutil reset AppleEvents "$BUNDLE_ID" 2>/dev/null || true
  tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
  sleep 2
  echo "  starting state:"; show_state
  open -a "$APP"
  echo
  ask "The setup window should appear on its own within a few seconds."
  ask "Walk it: Accessibility → Check Spotify → macOS asks to control Spotify → Allow"
  ask "  → the Spotify step turns green → Teams detected → press Start Syncing."
  ask "Then play a track and confirm it reaches your Teams status."
  echo
  echo "  when done:  $0 check"
  ;;

upgrade)
  require_app
  bold "Scenario B — a user upgrading from 1.0.0 (THE ONE THAT MATTERS)"
  quit_app
  defaults delete "$BUNDLE_ID" 2>/dev/null || true
  killall cfprefsd 2>/dev/null || true
  # Recreate exactly what 1.0.0 left behind: "Set up later" recorded completion, and the
  # source migration then read that flag as evidence of Web API use and wrote it down.
  defaults write "$BUNDLE_ID" hasCompletedOnboarding -bool YES
  defaults write "$BUNDLE_ID" sourceKind -string spotifyWebAPI
  tccutil reset AppleEvents "$BUNDLE_ID" 2>/dev/null || true
  killall cfprefsd 2>/dev/null || true
  sleep 2
  echo "  starting state (this is the stranded profile):"; show_state
  open -a "$APP"
  echo
  ask "Setup will NOT open by itself here, and that is correct — preferences say"
  ask "  setup is complete and Accessibility is still granted."
  ask "Open the menu-bar ♪ icon and press 'Set Up…'. That is the escape hatch."
  ask "Then: Check Spotify → macOS must ask to control Spotify → Allow → step turns green."
  ask "If it says 'Spotify is not connected' and no macOS dialog appears, the repair"
  ask "  did not run — that is a FAIL, report it."
  echo
  echo "  when done:  $0 check"
  ;;

check)
  bold "What the app decided"
  echo "  preferences now:"; show_state
  echo
  echo "  launch decisions recorded by the app:"
  log show --predicate "subsystem == \"$BUNDLE_ID\"" --last 30m --info --style compact 2>/dev/null \
    | grep -iE "setup check|moved to the local source|preserved the Spotify Web API|Keychain primed" \
    | tail -12 | sed 's/^/    /' || echo "    (none found — see note below)"
  echo
  src="$(defaults read "$BUNDLE_ID" sourceKind 2>/dev/null || echo '<unset>')"
  if [ "$src" = "spotifyLocal" ]; then
    ok "source is spotifyLocal — it can request Automation"
  else
    bad "source is '$src' — a stranded profile should have been repaired to spotifyLocal"
  fi
  chosen="$(defaults read "$BUNDLE_ID" sourceChosenExplicitly 2>/dev/null || echo 0)"
  if [ "$chosen" = "1" ]; then
    bad "sourceChosenExplicitly is set — the app must not forge a user decision"
  else
    ok "sourceChosenExplicitly unset — the repair did not masquerade as a user choice"
  fi
  echo
  echo "  Automation grant (should list Spotify after you allowed it):"
  sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
    "select service, client, auth_value from access where client='$BUNDLE_ID';" 2>/dev/null \
    | sed 's/^/    /' || echo "    (TCC.db unreadable from this shell — check System Settings instead)"
  echo
  echo "  Note: the decision log needs the app to have been launched since the fix. If no"
  echo "  lines appear, confirm you are running the 1.0.1 build and not the published 1.0.0."
  ;;

*)
  bold "Onboarding acceptance for v1.0.1"
  echo
  echo "  $0 fresh     put the machine in a new-user state and launch"
  echo "  $0 upgrade   recreate the stranded 1.0.0 profile and launch  <- the one that matters"
  echo "  $0 check     read back what the app decided"
  echo
  echo "  Run 'upgrade' as well as 'fresh'. A reset profile does not reproduce either"
  echo "  defect, so a fresh-only run passes while the bug is still there."
  exit 1
  ;;
esac
