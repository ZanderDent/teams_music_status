# Architecture

How Teams Rich Presence is put together, and why. Findings that shaped these decisions
are in [`FEASIBILITY.md`](FEASIBILITY.md); this document assumes them.

---

## Shape

```
┌─────────────────────┐
│ SpotifyWebAPISource │──┐
└─────────────────────┘  │   ┌──────────────────────┐      ┌───────────────┐
                         ├──▶│ PresenceCoordinator  │─────▶│ TeamsAXTarget │──▶ Teams
┌─────────────────────┐  │   │  (I/O, lifecycle)    │      └───────────────┘
│ SpotifyLocalSource  │──┘   └──────────┬───────────┘              │
└─────────────────────┘                 │                          │
                                        ▼                          ▼
                              ┌──────────────────┐      ┌──────────────────────┐
                              │   SyncEngine     │      │ TeamsAccessibility   │
                              │ (pure decisions) │      │ (health + enabler)   │
                              └──────────────────┘      └──────────────────────┘
```

Two protocols are the seams:

* **`PresenceSource`** — "what is playing?" Returns `TrackPresence?`, where `nil` means
  nothing is playing (a normal state, not an error).
* **`PresenceTarget`** — "show this." Teams today; a Windows UI Automation target would
  conform to the same thing.

Adding Apple Music, VS Code, or GitHub later means writing one `PresenceSource`. Nothing
in the coordinator or the Teams target needs to know.

---

## Module layout

SwiftPM requires non-overlapping target roots, so the conceptual grouping lives as
subdirectories:

```
Sources/
  TeamsRichPresenceCore/          library — everything testable
    Core/         PresenceSource, PresenceTarget, SyncEngine,
                  PresenceCoordinator, AppState, AppEnvironment
    Models/       TrackPresence, StatusTemplate
    Presence/     SpotifyWebAPI/, SpotifyLocal/
    Targets/      Teams/  (AXElement, TeamsAccessibility, TeamsAXTarget,
                           TeamsSelectors, TeamsSelfTest, TeamsProcesses)
    Services/     AppSettings, Keychain/, Logging/, LoginItem/
    Utilities/    UnicodeSanitizer
  TeamsRichPresenceApp/           executable — SwiftUI shell only
    App/  UI/MenuBar/  UI/Settings/  UI/Onboarding/
  trpctl/                         diagnostics + acceptance harness
Tests/TeamsRichPresenceCoreTests/
```

The executable holds no logic worth testing; everything else lives in the library so the
test target can reach it.

---

## The Teams target

### Why the Accessibility API at all

Teams 2.x is Microsoft Edge WebView2, not Electron. There is no Node integration, no
Electron IPC, and no listening DevTools port. Teams ships no AppleScript dictionary. The
Accessibility API is the only local automation surface, and — once its tree is published —
a good one: elements carry `AXDOMIdentifier`, which is the DOM `id`.

### Three invariants

**1. No coordinates.** Nothing reads `AXPosition`, `AXSize` or `AXFrame`. All navigation
is by DOM identifier or accessible name, catalogued in `TeamsSelectors`.

**2. `AXError.success` is never evidence.** Chromium routinely accepts an `AXPress` or an
attribute write, returns `.success`, and does nothing. Every interaction goes through
`AXActivator.activate`, which:

```
AXPress            → observe expected state transition?  → done
focus + Return     → observe?                            → done   (Space first for checkboxes)
focus + Space      → observe?                            → done
                   → otherwise fail explicitly
```

Text writes are verified by reading the compose box back, and commits by reading Teams'
own status readout. Nothing reports success it has not observed.

**3. No focus theft.** Key events go to the Teams pid via `CGEvent.postToPid`, never to
the global event stream. `AXFocused` moves the caret inside Teams without activating it.
Window repair uses non-activating APIs. Every acceptance case measures
`NSWorkspace.frontmostApplication` before and after.

### The accessibility enabler

The hardest part of the product. Chromium keeps its renderer accessibility tree switched
off until it believes an assistive technology is present, so a freshly launched Teams
exposes ~250 nodes — menu bar and window chrome — and no web content at all.

`TeamsAccessibility` holds a **live `AXObserver`** on the Teams process, pumped by a
dedicated run loop for the lifetime of the app, exactly as a screen reader does. When the
tree is missing it also **reads attributes off every `Microsoft Teams WebView` helper
process**, walking the tree and requesting `AXRole` at each node.

Reading matters, not counting. An earlier implementation walked the helper processes
counting children and failed for 46 seconds; adding the `AXRole` read at every node
materialises the tree in ~0.3 seconds. See `touchWebViewHelpers`.

`ensureHealthy` is a bounded, escalating repair loop over an explicit health model:

| Health | Repair |
|---|---|
| `permissionMissing` | fail — only the user can fix this |
| `notRunning` | fail — Teams must be running |
| `noWindow` | `NSWorkspace.openApplication(activates: false)`, then the AppleScript `reopen` verb |
| `minimized` | clear `AXMinimized`, **then `AXRaise`** |
| `treeUnavailable` | dismiss a stale flyout, then run the enabler |
| `healthy` | proceed |

Two of those repairs are less obvious than they look:

* **Un-minimizing is not enough.** The window returns and the tree reads perfectly — so
  `health()` says `.healthy` — yet Chromium still treats the window as occluded and
  discards every click. `AXPress` returned `.success` once a second for eight seconds
  without opening anything. `AXRaise` orders the window in and un-throttles the renderer,
  without activating the app.
* **A stale flyout looks exactly like a dead tree.** While the profile dialog is open,
  Chromium exposes only that dialog's subtree — the profile button disappears. A flyout
  left open by an interrupted run therefore presents as `treeUnavailable` forever. So
  `apply()` always closes the flyout on every exit path, and `ensureHealthy` presses
  Escape before blaming Chromium.

### Selector self-test

`TeamsSelectors` is the single place Teams UI knowledge lives. `TeamsSelfTest` drives the
real flyout and editor and reports which named selector stopped resolving.
`TeamsVersionTracker` records the last Teams build that passed, so the check runs on
upgrade rather than on every launch. On failure the app **disables automation and says
so** rather than thrashing against a UI it no longer recognises.

This is not hypothetical: Teams updated from `26183.1901.4874.5228` to
`26198.202.4929.7171` between Phase 0 and Phase 1. `AXDOMIdentifier` on the compose box
survived; `AXPlaceholderValue` became `nil`, and the checkbox's DOM id changed from
`checkbox-rd2` to `checkbox-rm1`. Both were caught by matching on more than one attribute.

---

## The sync rules

All of them live in `SyncEngine` — a pure function of (state, input, now) → action, with
no I/O, no timers and no Teams. That is what makes debounce, grace periods, save/restore
and override detection directly unit testable.

```swift
func step(state: inout State, input: Input, now: Date) -> Action
// Action = .doNothing | .write(String) | .restore(String?) | .reportManualOverride(found:)
```

Order of evaluation:

1. **Manual override.** If Teams shows something other than what the app last wrote, the
   user has taken over: latch, report, and stop writing. `observedTeamsStatus` is a
   *double* optional so "we did not look this tick" stays distinct from "we looked and it
   was empty".
2. **Not playing.** Start the idle clock. Inside the grace period, do nothing at all —
   resuming causes no churn. Past it, restore the user's original status (or clear it).
3. **Playing.** If the rendered text equals what we last wrote, do nothing. Otherwise it
   becomes a candidate and must stay unchanged for the debounce window before it is
   written.

`PresenceCoordinator` is the I/O shell: polling, threading, error classification, and
Teams launch/quit observation via `NSWorkspace`. Teams automation is blocking, so it runs
off the main actor to keep the menu bar responsive.

### Save and restore

`savedUserStatus` is captured on the **first** write and never overwritten. On disable,
the app restores it *only if Teams still shows what the app wrote* — the scenario from
the brief (app sets a status, user replaces it by hand, user disables) correctly keeps the
user's text.

Nothing about the previous status is persisted to disk. A crash therefore cannot cause the
app to overwrite a status the user has since set with a stale value; the cost is that a
crash loses the ability to restore, which is the safer failure.

---

## Spotify

### Web API (default)

OAuth 2.0 Authorization Code with **PKCE**, no client secret anywhere. A loopback
listener on `127.0.0.1:8888` catches the redirect (`localhost` was banned by Spotify on
27 November 2025), `state` is verified, and tokens go straight to the Keychain.

The subtlety worth knowing: **Spotify answers an insufficient-scope request with
`401 "Permissions missing"`, not `403`.** A naive "401 → refresh → retry" loop spins
forever against a grant that refreshing cannot repair. `SpotifyWebAPISource.classify`
inspects the message body and maps that case to `.permissionsMissing`, which the UI turns
into "reconnect Spotify" instead of an endless retry.

`204 No Content` is the real "nothing is playing" response, despite the documentation
describing `200` with `is_playing: false`. Both are handled.

`429` is honoured via `Retry-After`, and the coordinator's poll interval backs off to
match. This path is implemented from the HTTP contract — Phase 0 could not provoke a real
429 (200 requests at 5.2 req/s did not trip it), so it is **not empirically demonstrated**.

### Local (AppleScript)

Reads the Spotify desktop app's scripting dictionary. No OAuth, no network, no quota.
Sees only this Mac, and reports only the primary artist. The `is running` check sits
*outside* the `tell` block on purpose — addressing a non-running app inside `tell` would
launch Spotify as a side effect of a read.

---

## Application states

`AppState` enumerates every situation the menu bar can describe, each with a title, a
one-sentence explanation, and a severity that drives the icon. There is no generic error
case: if the app cannot say what is wrong, that is a bug.

---

## Threading

* SwiftUI, `PresenceCoordinator` and `AppSettings` are `@MainActor`.
* Teams automation is synchronous and blocking; the coordinator hops to a global queue.
* `TeamsAXTarget` serialises on a recursive lock — the flyout is global UI state, so two
  concurrent writes would interleave and corrupt each other.
* The `AXObserver` owns a dedicated thread with its own run loop, kept alive by a timer.

## Logging

`os.Logger`, one category per subsystem. Tokens, authorization codes and PKCE verifiers
are never logged; `Redact.secret` renders a length and nothing else, and `Redact.status`
keeps status text short since it is personal. Verbose diagnostics are opt-in via
`TRP_DEBUG=1` or the `debugLogging` default.
