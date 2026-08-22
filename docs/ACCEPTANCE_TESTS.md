# Acceptance tests

Manual verification against **real** Microsoft Teams and a **real** Spotify account.
Unit tests (`swift test`) cover the decision logic; this document covers everything that
can only be proven by driving the actual applications.

Automated where possible: `tmsctl gate` runs the Teams window-state matrix unattended and
restores your original status afterwards. The rest needs a human.

> These tests change your real Teams status. Note what it says first — every procedure
> ends by putting it back.

---

## Before you start

```sh
swift run tmsctl version     # confirm the installed Teams version
swift run tmsctl selftest    # confirm every selector still resolves
```

If the self-test fails, stop: the Teams UI has changed and `TeamsSelectors` needs updating
before anything else is meaningful.

Record the environment with each run:

| | |
|---|---|
| macOS | |
| Teams version | |
| App version / commit | |
| Source under test | Web API / Local |

---

## A. Hard Gate — Teams automation (automated)

```sh
swift run tmsctl gate --with-restart
```

Runs, in order, restoring your original status at the end:

| # | Case | Passes when |
|---|---|---|
| 0 | Selector self-test | every required selector resolves |
| 1 | Teams open, backgrounded | status written and read back identical |
| 2 | Consecutive update | a second write lands |
| 3 | Teams minimized | recovers and writes |
| 4 | Teams window closed | reopens without activating, then writes |
| 5 | Teams quit and relaunched | recovers and writes |
| 6 | Restore original status | Teams shows the original again |

**Every case additionally asserts that the frontmost application did not change.** A run
with any `focus✗` is a failure even if the status was written.

Omit `--with-restart` to skip case 5 (the disruptive one).

### On Windows

```powershell
.\.build\debug\tmswinctl.exe gate
```

Same contract — writes several statuses, restores the original at the end, and fails the
run if anything stole the foreground. The matrix is shorter:

| # | Case | Passes when |
|---|---|---|
| 0 | Selector self-test | every required selector resolves |
| 1 | Teams open, backgrounded | status written and read back identical |
| 2 | Consecutive update | a second write lands |
| 3 | Teams minimized | recovers and writes |
| 4 | Sanitized unicode | astral scalars substituted, then written and read back |
| 5 | Restore original status | Teams shows the original again |

Cases 4 and 5 of the macOS matrix — *window closed* and *quit and relaunched* — are **not**
covered on Windows. Both are reported as unrecoverable rather than repaired, because
relaunching Teams is a visible action the app should not take unasked. See
[`WINDOWS.md` §12](WINDOWS.md#12-what-is-not-done-yet).

---

## B. Application lifecycle

| # | Steps | Expected |
|---|---|---|
| B1 | `./scripts/build-app.sh --run` | App appears in the menu bar. **No Dock icon**, no app switcher entry. |
| B2 | First launch on a clean profile | Onboarding window appears explaining Accessibility. |
| B3 | Revoke Accessibility in System Settings, relaunch | Menu bar shows *Needs Accessibility permission*; onboarding reappears. |
| B4 | Grant Accessibility while the app is running | Permissions tab flips to *Granted* within ~2s without a restart. |
| B5 | Settings ▸ General ▸ Launch at login, toggle on, reboot | App starts automatically. |
| B6 | Quit from the menu | Process exits; menu-bar item disappears. |

---

## C. Spotify — Web API source

| # | Steps | Expected |
|---|---|---|
| C1 | Menu bar ▸ **Connect Spotify…** | Browser opens the Spotify consent page. |
| C2 | Approve | Browser shows "Spotify connected"; menu bar shows the current track. |
| C3 | Deny instead | Friendly "sign-in was cancelled" message, no crash. |
| C4 | Start playback | Track and artists appear in the menu-bar panel within one poll. |
| C5 | Quit the app, relaunch | Still connected — tokens came from the Keychain. |
| C6 | `security find-generic-password -s com.zanderdent.TeamsMusicStatus.spotify` | An entry exists. Its value is a token, so do not paste it anywhere. |
| C7 | Play from your **phone**, not this Mac | Menu bar still shows the track (this is what the Web API source is for). |
| C8 | Disconnect Spotify | State becomes *Spotify not connected*; the Keychain item is gone. |
| C9 | Turn off Wi-Fi for a poll cycle | State becomes *Spotify unreachable*; app does not crash; recovers when the network returns. |

## D. Spotify — Local source

| # | Steps | Expected |
|---|---|---|
| D1 | Settings ▸ source = **Local Spotify** | macOS prompts for Automation permission the first time. |
| D2 | Deny it | Clear message pointing at System Settings ▸ Automation. No crash. |
| D3 | Approve, play something | Track appears. Note it shows the **primary artist only**. |
| D4 | Quit the Spotify app | State becomes *Nothing playing*; Spotify is **not** relaunched. |
| D5 | Switch back to Web API | No Automation permission needed again. |

---

## E. Sync behaviour

Enable **Sync Spotify to Teams** first, and note your original Teams status.

| # | Steps | Expected |
|---|---|---|
| E1 | Play a track | Teams status becomes `♪ <track> by <artists>` within ~10s (poll + debounce). |
| E2 | Verify in Teams by hand | Profile ▸ the status matches exactly. |
| E3 | Skip to another track | Status follows. |
| E4 | Skip 5 tracks rapidly, then settle | **One** final Teams update, not five. Watch the flyout: it should open once. |
| E5 | Let a track loop / just wait | Teams is **not** touched again. |
| E6 | Pause | Status stays put initially. Menu bar shows *Paused — track*. |
| E7 | Resume within the grace period | No Teams edit at all. |
| E8 | Pause and wait out the grace period (set it to 30s in Settings to test) | Original status restored. |
| E9 | Stop playback entirely, wait out the grace | Original status restored (or cleared, if you had none). |
| E10 | Turn sync off while a track is playing | Original status restored. |
| E11 | Turn sync off after manually changing your status | Your manual text is **kept**, not overwritten. |

## F. Manual override

| # | Steps | Expected |
|---|---|---|
| F1 | With sync on and a status showing, change your Teams status by hand to `In site meeting` | Within a poll or two the menu bar shows *Manual status detected* and stops writing. |
| F2 | Change tracks | Teams status stays `In site meeting`. |
| F3 | Click **Resume automatic updates** | Syncing resumes; the next track updates Teams. |
| F4 | Now turn sync off | `In site meeting` is treated as the new baseline, not overwritten with the pre-app status. |

## G. Teams lifecycle during sync

| # | Steps | Expected |
|---|---|---|
| G1 | Minimize Teams, change track | Status updates; Teams window is restored and raised, **focus unchanged**. |
| G2 | Close the Teams window (⌘W), change track | Window reopens without activating; status updates. |
| G3 | Quit Teams | Menu bar shows *Teams not running*. No errors, no spinning. |
| G4 | Relaunch Teams | Recovers automatically within ~30s; next change updates. |
| G5 | Throughout G1–G4 | Keep typing in another app. Not one keystroke should be lost or land in Teams. |

## H. Status text

| # | Steps | Expected |
|---|---|---|
| H1 | Settings ▸ Status, set template to `🎵 {track}` | Preview shows `♪ …` — the emoji is substituted, and it says so. |
| H2 | Play a track with a long title and set the template to include `{album}` | Output ≤ 280 characters; album dropped before any truncation. |
| H3 | Play a track with a non-English title (accents, CJK) | BMP characters reach Teams intact. |
| H4 | Set the template to `{artists}` with a multi-artist track (Web API) | All artists appear, comma separated. |

## I. Teams UI change detection

| # | Steps | Expected |
|---|---|---|
| I1 | Settings ▸ Diagnostics ▸ **Run self-test** | Report lists every selector with PASS/WARN/FAIL. |
| I2 | Edit `TeamsSelectors.composeBox` to a nonsense identifier, rebuild, run the self-test | FAIL naming `composeBox`; sync disables itself with *Teams UI changed*. |
| I3 | Revert | Passes again; the tested version is recorded. |

## J. Security

| # | Check | Expected |
|---|---|---|
| J1 | `log show --predicate 'subsystem == "com.zanderdent.TeamsMusicStatus"' --last 1h` | No token, refresh token, authorization code or PKCE verifier. Only lengths. |
| J2 | `defaults read com.zanderdent.TeamsMusicStatus` | Preferences only — no credentials. |
| J3 | `grep -ri "client_secret\|SPOTIFY_CLIENT_SECRET" Sources/` | No matches. |
| J4 | `git log -p -- .env` | Nothing; `.env` is ignored and never committed. |

---

## Recording results

Copy this into the pull request or issue:

```
Environment: macOS __ | Teams __ | commit __
A. Hard gate:       __/7    (focus preserved: yes/no)
B. Lifecycle:       __/6
C. Spotify Web:     __/9
D. Spotify Local:   __/5
E. Sync behaviour:  __/11
F. Manual override: __/4
G. Teams lifecycle: __/5
H. Status text:     __/4
I. UI change:       __/3
J. Security:        __/4

Failures / notes:
```

---

## Phase 1 acceptance run — 14 August 2026

Environment: macOS 15.3.1 (arm64, M1 Pro) · Teams **26198.202.4929.7171** · Spotify 1.2.96.518

| Area | Result |
|---|---|
| Unit tests | **74 / 74 pass** (`swift test`) |
| A. Hard gate (`tmsctl gate --with-restart`) | **7 / 7**, focus preserved in every case |
| A. Hard gate re-run after later fixes (no `--with-restart`) | **6 / 6**, focus preserved |
| B. Menu-bar app, no Dock icon, onboarding on first run | pass |
| C. Spotify Web API: connect via the app's own button, token in Keychain, redacted in logs | pass |
| C. Track/artist/album/playing read from the real account | pass |
| D. Spotify Local: reads the desktop app, primary artist only | pass, in-app, after adding the apple-events entitlement |
| E1–E3. Play / verify in Teams / track change | pass |
| E4. Four rapid skips → **one** Teams update | pass |
| E5. Idle: Teams untouched between changes | pass |
| E6–E7. Pause and resume inside the grace period | pass, with a caveat (below) |
| E8–E9. Pause past the grace period → previous status restored | pass |
| E10. Disable → restore previous status | pass |
| E11. Disable after a manual edit → user's text kept | pass |
| F1–F2. Manual edit detected, overwrites stop | pass |
| G. Teams minimized / window closed / quit+relaunched | pass (via the gate) |
| H. Emoji substitution, 280 clamp, album dropped first | pass (unit tested) |
| I. Selector self-test names the broken selector | pass |
| J. Security sweep: no secrets, no tokens in logs, `.env` never committed | pass |

### Caveats observed

* **The Spotify Web API's `is_playing` lags real playback by several seconds.** With the
  grace period set to 30s for testing, a pause/resume near the boundary can produce one
  extra write or a slightly late restore. Irrelevant at the 5-minute default, and absent
  from the local source. Not a defect in the sync logic.
* **"Show when people message me" is reported as a warning on every write** because Teams
  does not expose the checkbox's state (see README). Non-fatal by design.
* **F3 (Resume automatic updates button) and E-toggle cases were driven by script**, and
  the MenuBarExtra panel auto-closes when it loses focus, which makes UI scripting flaky.
  These paths are unit tested; the on-screen button was not clicked by a human in this run.

### Defects found by this run, and fixed

1. Accessibility enabler did not work after a Teams restart — the WebView helper walk has
   to *read attributes*, not just count children.
2. Un-minimizing left Chromium throttled; `AXRaise` is required before input is accepted.
3. A stale flyout wedged the tree permanently, because the Escape meant to dismiss it was
   itself being dropped by the throttled window.
4. `savedUserStatus` lived only in memory, so relaunching made the app adopt its own
   leftover status as the user's baseline.
5. A Keychain read on the main thread during launch hung the app with no UI and no logs.
6. The self-test blamed three selectors when it had merely failed to open the editor,
   which permanently disabled sync.
7. The signed app was missing `com.apple.security.automation.apple-events`. Because it
   is signed with the hardened runtime, macOS refused every Apple Event with -1743 and
   never showed a consent prompt — indistinguishable from the user denying access. This
   made the Local Spotify source and the AppleScript window-reopen fallback impossible
   in any signed build. Compounding it, `codesign` hands the entitlements file to AMFI,
   whose parser rejects XML comments, so an annotated entitlements file was silently
   ignored and produced the same symptom.
