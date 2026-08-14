#!/bin/zsh
# restart_probe.sh — Experiment B7: how long after a Teams restart does the WebView2
# accessibility tree become usable, and does touching the WebView helper process
# accelerate it?
#
# Phase 1 (0-90s):  poll the MAIN app element only — no WebView pid contact.
# Phase 2 (90s+):   additionally query each "Microsoft Teams WebView" helper pid,
#                   which is Chromium's AT-detection surface.
#
# If the tree flips during phase 1, materialisation is just load time.
# If it flips immediately on entering phase 2, the helper-pid query is the trigger.
#
# Usage: ./restart_probe.sh          (quits and relaunches Teams — disruptive)
#        ./restart_probe.sh --no-restart   (probe the running instance)
set -u
cd "$(dirname "$0")"

command -v ./nodecount >/dev/null 2>&1 || swiftc -O nodecount.swift -o nodecount 2>/dev/null

if [[ "${1:-}" != "--no-restart" ]]; then
  echo "[$(date +%T)] quitting Teams…"
  osascript -e 'tell application id "com.microsoft.teams2" to quit' 2>/dev/null
  for i in $(seq 1 30); do pgrep -f 'MacOS/MSTeams' >/dev/null || break; sleep 1; done
  echo "[$(date +%T)] terminated. relaunching…"
  open -a "Microsoft Teams"
fi

START=$(date +%s)
PHASE=1
while :; do
  NOW=$(date +%s); T=$((NOW - START))
  if (( T >= 90 )) && (( PHASE == 1 )); then
    PHASE=2
    echo "[$(date +%T)] --- entering PHASE 2: now also querying WebView helper pids ---"
  fi
  if (( PHASE == 2 )); then
    ./nodecount --touch-webview >/dev/null 2>&1
  fi
  N=$(./nodecount 2>/dev/null)
  echo "[$(date +%T)] t=${T}s phase=${PHASE} mainAppNodes=${N}"
  if [[ -n "$N" ]] && (( N > 400 )); then
    echo "[$(date +%T)] >>> TREE MATERIALISED at t=${T}s during phase ${PHASE}"
    ./teamsctl find role=AXButton 'desc~=Your profile'
    break
  fi
  (( T > 420 )) && { echo "give up after 7 min"; break; }
  sleep 5
done
