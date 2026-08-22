# Windows port

How the Windows build works, what was measured to get there, and — in the spirit of
[`FEASIBILITY.md`](FEASIBILITY.md) — everything that *did not* work, because several of
the obvious approaches fail silently and look like success.

This document answers the open questions in
[`FEASIBILITY.md` §13](FEASIBILITY.md#13-windows-port-considerations). One of them was
answered the other way round from what was expected; see
[§7](#7-corrections-to-the-original-windows-port-predictions).

---

## 0. Verdict up front

**Feasible, and the automation is in some respects better behaved than on macOS.**

* Teams 2.x on Windows is the same web application, exposing the **same DOM ids**. UI
  Automation's `AutomationId` carries what `AXDOMIdentifier` carries on macOS, and `Name`
  carries `AXDescription`. `TeamsSelectors.swift` is shared verbatim.
* **Background writes without focus theft work.** The Hard Gate passes 6/6 with the
  foreground window unchanged throughout.
* **No permission grant is required at all.** There is no Windows equivalent of the
  Accessibility permission prompt, and no equivalent of the Apple Events grant for reading
  the player.
* The presence source is *simpler and richer* than on macOS: the system media session
  reports album and every artist, where the AppleScript interface exposes only the primary
  artist.

The cost is that acting on the tree needs **two APIs, not one** — UI Automation to read,
MSAA to act — for reasons measured in [§3](#3-activating-controls).

---

## 1. Environment tested

| | |
|---|---|
| Windows | 11 Pro 26100, **ARM64** |
| Teams | **26213.1006.5014.9784** (MSIX, arm64) |
| Spotify | 1.296.518.0 (MSIX, arm64) |
| Swift | 6.3.3, `aarch64-unknown-windows-msvc` |
| Toolchain | VS 2022 Build Tools 17.14.39 · MSVC 14.44.35207 · Windows SDK 10.0.26100.0 |

ARM64 is worth noting: nothing here depends on the architecture, but it does mean the
whole stack — Teams, Spotify, WebView2 and the toolchain — was exercised on arm64 native
rather than under emulation.

---

## 2. The accessibility tree is off until it is *read*

Chromium keeps its renderer accessibility tree switched off until it believes an assistive
technology is present. This is [§2.6](FEASIBILITY.md) again, in a different API, exactly as
predicted.

A freshly observed Teams window exposes its window chrome and stops at
`Document 'WebView'` with no children. The web content is simply not there.

**What opens it:**

```
SendMessageTimeout(renderWidget, WM_GETOBJECT, 0, OBJID_CLIENT)
AccessibleObjectFromWindow(renderWidget, OBJID_CLIENT, IID_IAccessible)
  → then walk it, reading accName / accRole / accState at every node
```

**Holding the `IAccessible` is not enough.** Obtaining the reference and keeping it alive
leaves the tree dead; the tree materialises only once it is *read through*. This is the
same distinction the macOS implementation found in `touchWebViewHelpers` — "reading
matters, not counting", where adding an `AXRole` read at each node turned a 46-second
failure into a 0.3-second success.

The tree also **lapses** when nothing is reading it, so `tw_open()` is called before every
operation rather than once at startup.

`Chrome_RenderWidgetHostHWND` is the window that answers `WM_GETOBJECT`. It is *not* the
window that accepts input — see [§4](#4-delivering-keys).

---

## 3. Activating controls

The load-bearing finding of the port. Measured against live Teams with a controlled
non-Teams foreground window, repeated to confirm:

| Method | Opens the flyout | Steals foreground |
|---|---|---|
| UIA `SetFocus()` | no | **yes** |
| UIA `ExpandCollapsePattern.Expand()` | yes | **yes** |
| UIA `LegacyIAccessible.DoDefaultAction()` | **no** | no |
| **MSAA `accDoDefaultAction`** | **yes** | **no** |
| MSAA `accSelect(TAKEFOCUS)` + posted Return | yes | no |

Only MSAA does both. Three details make this less obvious than the table suggests:

**UI Automation's bridge to MSAA is a dead end.** `IUIAutomationLegacyIAccessiblePattern`
exists on the element and reports `DefaultAction = "Press"`, but calling it does nothing,
and `GetIAccessible()` returns **null** on Chromium. The working route is to navigate MSAA
independently, from `AccessibleObjectFromWindow`, and call `accDoDefaultAction` on the node
found there.

**`ExpandCollapseState` lies.** It reports `Collapsed` while the flyout is demonstrably
open. Any code that trusts it will conclude the press failed and press again.

**`SetFocus` is the thief, not the press.** Isolating it showed `SetFocus` alone steals the
foreground while doing nothing else, which is why the whole focus-free path had to avoid
UI Automation's activation entirely.

---

## 4. Delivering keys

The Windows counterpart of `CGEvent.postToPid`. Two details are load-bearing, and getting
either wrong produces silence rather than an error:

**Post to `Chrome_WidgetWin_1`, not `Chrome_RenderWidgetHostHWND`.** The render-widget
window carries accessibility; the browser widget carries input. Posting Escape to the
former does nothing at all.

**`lParam` must carry the real scan code** (`MapVirtualKey(vk, MAPVK_VK_TO_VSC)`). Chromium
reads it, and **silently discards a key posted with a zero `lParam`**. This one cost real
time: the message arrives, the call succeeds, and nothing happens.

With both right, Chromium processes posted keys **while unfocused**, and the window is
never activated.

---

## 5. Entering text

The status compose box is a CKEditor contenteditable, not a text control. Measured by
reading back what actually landed:

| Method | Result |
|---|---|
| UIA `ValuePattern.SetValue` | accepted, **field unchanged** |
| posted `Ctrl+A` | inserts a literal `a`, selects nothing |
| **End + N × Backspace, then `WM_CHAR`** | **exact match** |

`SetValue` reaches the DOM without CKEditor's model ever seeing it — the same class of
failure as `AXError.success` on macOS.

`Ctrl+A` fails for a different and more interesting reason: **Chromium derives modifier
state from the receiving thread's keyboard**, which `PostMessage` does not touch. The
control modifier is therefore never seen, the `a` arrives unmodified, and the field is
*corrupted* rather than cleared. Backspace needs no modifier, so clearing is End followed
by N backspaces, with the field read back to confirm it actually emptied.

`WM_CHAR` delivered `♫` (U+266B) and `—` (U+2014) intact.

> **Open question.** Whether Windows shares the macOS limitation that astral-plane scalars
> (`🎵`, U+1F3B5) are dropped in flight has **not** been tested. `UnicodeSanitizer`
> substitutes them before they reach the input path, so the gate exercises the substituted
> text, not the raw character. If Windows can deliver surrogate pairs, the substitution
> could be relaxed on this platform — but that is an untested hypothesis, not a finding.

---

## 6. Two Chromium quirks that break verification

Both were found by a read-back disagreeing with what had just been written, which is
precisely why the "verify everything" rule exists.

**An edit's accessible name is its *label*, not its content.** For the compose box that is
the placeholder. Falling back to the name when `ValuePattern` is empty — correct for static
text, where the "22 / 280" counter lives in the name — makes an *empty* field read as full.

**CKEditor renders its placeholder as real text inside the contenteditable.** An empty
compose box therefore reports `"Type @ to mention someone in your status"` as its
accessible value. Taken at face value, a successfully cleared field looks unchanged and
clearing can never be verified. A value equal to the placeholder is treated as empty.

**A stale flyout still looks like a dead tree**, exactly as on macOS: while the profile
dialog is open Chromium exposes only that subtree, so the avatar button vanishes. Recovery
presses Escape before blaming Chromium.

---

## 7. Corrections to the original Windows-port predictions

[`FEASIBILITY.md` §13](FEASIBILITY.md#13-windows-port-considerations) was written before any
Windows spike. Recording where it was right and wrong, because the wrong ones were wrong in
the direction that would have killed the port:

| Prediction | Outcome |
|---|---|
| `PresenceTarget` is the right seam | **Confirmed.** No coordinator changes were needed. |
| Windows Teams is WebView2, expect §2.6 again | **Confirmed**, in the UI Automation form. |
| `AutomationId` maps to the same DOM ids | **Confirmed** — `status-note-compose` resolves. |
| "`ValuePattern.SetValue` / `InvokePattern` are more reliable than `AXPress`" | **Wrong.** `SetValue` does nothing on CKEditor, and `InvokePattern` is not exposed on the avatar at all. |
| "Text entry into CKEditor will still likely need `SendInput`" | **Wrong.** `WM_CHAR` works, and `SendInput` — being global — would have been unusable anyway. |
| "`PostMessage`/`WM_CHAR` to a Chromium HWND is unreliable" | **Wrong**, and this mattered most. It is reliable, given the right HWND and a real scan code in `lParam`. Both are easy to get wrong in a way that looks like unreliability. |
| **"Background updates without focus theft may not be achievable on Windows"** | **Wrong.** They are. The gate passes 6/6 with the foreground unchanged. This was called the single biggest portability unknown; it is now closed. |
| "a shared Rust core with two native shells, or two native apps" | **Superseded.** Swift on Windows shares `TeamsMusicStatusCore` directly, including `TeamsSelectors`. |

---

## 8. How the code is arranged

The Windows build compiles a **subset of the existing `TeamsMusicStatusCore`**, not a copy
of it. Thirteen files there import nothing but Foundation and are byte-identical across
platforms.

```
Sources/
  TeamsMusicStatusCore/          shared; on Windows, the portable subset only
    Core/AccessibleElement.swift        Windows-only: AccessibleElement, AXSelector, AXPoll
    Services/Logging/WindowsLog.swift   Windows-only: Log, Redact
  CTeamsWin/                     C ABI over UIA, MSAA, WinRT and Win32
    Media.cpp                      GlobalSystemMediaTransportControlsSession
    Teams.cpp                      tree, activation, key delivery, window health
    Tray.cpp                       notification-area icon, menu, message loop
    Dialogs.cpp                    settings and onboarding windows
  TeamsMusicStatusWindows/
    UIAElement.swift                    UIA snapshot presented in AX vocabulary
    TeamsWindowsTarget.swift            PresenceTarget
    TeamsWindowsHealth.swift            health model, repair, focus instrumentation
    WindowsMediaSource.swift            PresenceSource
    WindowsSettings.swift               preferences, JSON under %APPDATA%
    WindowsLoginItem.swift              launch at login, HKCU Run key
    WindowsPresenceCoordinator.swift    the sync loop
  TeamsMusicStatusWin/           the application — tray icon, menu, onboarding
  tmswinctl/                     diagnostics harness, mirroring tmsctl

scripts/
  build-windows.ps1              release build + staged self-contained folder
  release-windows.ps1            versioned zip, checksum, optional signing
  windows-install/               Install.ps1 and Uninstall.ps1, shipped in the zip
```

`Package.swift` gains a `#if os(Windows)` branch; the macOS manifest is preserved verbatim.
Sources are an explicit **allow-list** rather than an exclusion, so a new macOS-only file
cannot silently break the Windows build.

### Why `TeamsSelectors` is shared unchanged

Its predicates are written with an inferred parameter type — `AXElement` on macOS,
`any AccessibleElement` on Windows. Both expose the same seven properties, so one file
stays the single auditable place Teams UI knowledge lives, which is what
`CONTRIBUTING.md` requires. `UIAElement` maps UI Automation onto the macOS vocabulary:

| Protocol | macOS | Windows |
|---|---|---|
| `role` | `AXRole` | `ControlType`, mapped to AX role names |
| `subrole` | `AXSubrole` | synthesised (`Window` → `AXApplicationDialog`) |
| `title` | `AXTitle` | `Name` |
| `axDescription` | `AXDescription` | `Name` |
| `value` | `AXValue` | `ValuePattern`, falling back to `Name` for non-edits |
| `placeholder` | `AXPlaceholderValue` | `HelpText` |
| `domIdentifier` | `AXDOMIdentifier` | `AutomationId` |

`title` and `axDescription` both map to `Name` because UI Automation has one string where
the macOS API has two. That is a widening, not a narrowing.

**One selector needed changing.** `clearAfterPopup` now accepts `AXButton` as well as
`AXPopUpButton`: macOS models the clear-duration control as a pop-up button, Windows
reports the same control as a plain Button with an ExpandCollapse pattern. Only the match
is widened, so macOS behaviour is unchanged. The alternative — having `UIAElement` claim a
role the element does not have — would have mislabelled the avatar, and `profileButton`
requires `AXButton`.

### Selectors observed on Windows

Verified against Teams 26213.1006.5014.9784, with the same values the macOS selectors match:

```
Button   'Your profile, status Available '   [idna-me-control-avatar-trigger]
Window   'Profile menu'
Edit     'Your current status message: … . This will be displayed until '
Button   'Edit status message'               [idna-me-control-set-status-message-icon-trigger]
Button   'Delete status message'
Edit     'Type @ to mention someone …'       [status-note-compose]
Text     '22 / 280'
CheckBox 'Show when people message me'       [checkbox-rfh]
Button   'Clear status message after Never'  [me-control-set-status-message-clear-status-message-after-button]
Button   'Done'                              [me-control-set-status-message-update-status-message-button]
```

`checkbox-rfh` is worth noting: macOS recorded `checkbox-rd2` and then `checkbox-rm1`
across two Teams builds. The id is auto-generated and unstable on both platforms, which is
why the selector matches on the title as a co-equal check rather than a fallback.

---

## 9. Window health

Mirrors the macOS health model. Every repair is non-activating.

| Health | Repair |
|---|---|
| `notRunning` | fail — only the user can fix this |
| `noWindow` | fail — launching Teams would be a visible, unasked-for action |
| `minimized` | `SW_SHOWNOACTIVATE`, then `SetWindowPos(HWND_TOP, SWP_NOACTIVATE)` |
| `treeUnavailable` | Escape any stale flyout, then re-open the tree |
| `healthy` | proceed |

**Un-minimising is not cosmetic.** A minimised Chromium window is treated as occluded and
silently discards interactions, so automation against a minimised Teams fails in the most
confusing way available: every call succeeds and nothing happens. This is the same trap the
macOS implementation hit, where `AXRaise` turned out to be required after clearing
`AXMinimized`.

`SW_RESTORE` is deliberately not used — it activates.

---

## 9a. The application

A notification-area icon, no window unless you ask for one — the same shape as the macOS
menu-bar app. Four Apple frameworks had to be replaced outright:

| macOS | Windows |
|---|---|
| `os_log` | `WindowsLog` — a rotating file under `%LOCALAPPDATA%`, keeping `os_log`'s **private-by-default** interpolation so the secrets rule stays enforceable in shared code |
| `UserDefaults` + Combine | `WindowsSettings` — JSON under `%APPDATA%`, written atomically |
| `SMAppService` | `WindowsLoginItem` — the `HKCU` Run key |
| `PresenceCoordinator` (`NSWorkspace`) | `WindowsPresenceCoordinator` |

The rules did **not** need replacing. `SyncEngine` is shared and unit tested, so debounce,
pause grace, manual-override detection and save/restore behave identically on both
platforms; the coordinator only gathers inputs and carries out answers.

Three Win32 details are load-bearing, and each was found by something failing rather than
by reading a document:

**WinRT deadlocks on a single-threaded apartment.** The media session is read with a
blocking `.get()`, which requires an MTA. The tray application's main thread ends up an
STA, so the first build hung on launch with no window, no error, and no log line past
`starting` — the worst kind of failure to diagnose. Every media read now runs on a
dedicated MTA thread and joins, so the code no longer cares what apartment the caller is
in. `tmswinctl` never hit this, because its main thread was never made an STA. A CLI
passing is not evidence a GUI will.

**Onboarding claimed Teams was not running while it plainly was.** The health model reports
`treeUnavailable` until something opens the accessibility tree, which is not the same as
Teams being absent.

**Explorer can restart and take every tray icon with it.** It broadcasts `TaskbarCreated`
afterwards; an application that ignores it keeps running with no icon and no way to reach
it, which a user reads as a crash.

The icon is drawn at run time with GDI rather than loaded from a resource — SwiftPM cannot
compile a `.rc` file, and drawing it keeps the executable self-contained. Colour carries
state: muted when off, Teams purple when syncing, red when something needs attention.

Onboarding reports what was detected *before* asking for anything, and closing it without
finishing deliberately does not mark it complete — so it is offered again rather than
leaving the app in a state the user never agreed to. ("Set up later" meaning "never" was a
real bug on macOS.)

## 10. Building and testing

```powershell
# Once: MSVC + the Windows SDK, and the Swift toolchain
winget install Microsoft.VisualStudio.2022.BuildTools --override `
  "--quiet --wait --add Microsoft.VisualStudio.Component.VC.Tools.ARM64 `
   --add Microsoft.VisualStudio.Component.Windows11SDK.26100"
winget install Swift.Toolchain

# Every shell: import the MSVC environment, then restore SDKROOT
cmd /c '"…\VC\Auxiliary\Build\vcvarsarm64.bat" && set' | ForEach-Object {
  if ($_ -match '^([^=]+)=(.*)$') { Set-Item "Env:$($matches[1])" $matches[2] }
}
$env:SDKROOT = [Environment]::GetEnvironmentVariable('SDKROOT','User')

swift build
swift test
```

> **Gotcha.** `vcvarsarm64.bat` replaces the whole environment block, which drops the Swift
> installer's `SDKROOT`. Without it `swiftc` fails with
> `unable to load standard library for target aarch64-unknown-windows-msvc`, which does not
> obviously point at the cause.

Before opening a pull request that touches the Teams automation:

```powershell
swift test                                  # unit tests must pass
.\.build\debug\tmswinctl.exe teams-selectors   # selectors still resolve
.\.build\debug\tmswinctl.exe gate              # automation still works end to end
```

`tmswinctl gate` is the Windows equivalent of `tmsctl gate`. It writes several statuses,
minimises Teams to exercise recovery, restores the original status, and **exits non-zero if
any case fails or if anything stole the foreground**.

`tmswinctl teams-try-text` exercises the whole text-entry path but never presses **Done**,
so the write path can be developed without touching a published status. `tmswinctl run`
runs the real sync loop in a terminal — exactly what the tray application runs.

### Packaging

```powershell
.\scripts\release-windows.ps1                                  # unsigned
.\scripts\release-windows.ps1 -CertificateThumbprint <sha1>    # signed
```

Produces `dist\Teams-Music-Status-<version>-win-<arch>.zip` (~22 MB) containing the two
executables, the Swift runtime, and `Install.ps1` / `Uninstall.ps1`.

> **The Swift runtime has to ship with the app.** `--static-swift-stdlib` is accepted on
> Windows and silently does nothing — the binary still imports `swiftCore.dll`. The build
> walks the actual import graph and copies only what is reachable, which is 15 DLLs and
> 55 MB rather than the full 61 MB. `_FoundationICU.dll` alone is 36 MB of that; it is the
> price of using Foundation.

Installing is per-user and needs no administrator rights: the app goes to
`%LOCALAPPDATA%\Programs`, with a Start Menu shortcut and an Installed Apps entry so it can
be removed the ordinary way. A machine-wide install would need elevation and would put one
person's music on a shared machine.

**The uninstaller closes the app rather than killing it**, and waits. The shutdown path is
what restores the status the user had before syncing, and a force-kill skips it — stranding
whatever track happened to be showing. If the wait times out it says so, rather than
claiming a restore that did not happen.

Builds are unsigned unless a certificate thumbprint is passed, matching the macOS policy
that signing material stays off the repository and releases are signed on the maintainer's
machine. Unsigned means SmartScreen warns on first run.

---

## 11. Gate result

```
Hard Gate 0 — Teams automation acceptance (Windows)
Teams version: 26213.1006.5014.9784

  [PASS] selector self-test                   5 selectors checked, 4 resolved
  [PASS] 1. backgrounded              focus✓ read back "♫ Gate 1 backgrounded"
  [PASS] 2. consecutive update        focus✓ read back "♫ Gate 2 second write"
  [PASS] 3. minimized → recovered     focus✓ read back "♫ Gate 3 minimized"
  [PASS] 4. sanitized unicode         focus✓ read back "♪ Gate 4 astral"
  [PASS] restore original status              now "♫ Osos - 963Hz — Mzarta Brokin"
  6/6 passed, focus preserved throughout
```

`setStatusItem` is the one unresolved selector, correctly: Teams shows it *instead of* the
status readout, and a status was set.

---

## 12. What is not done yet

Honest scope. The app is usable end to end — onboarding, tray, settings, syncing, install
and uninstall — and these are the gaps.

* **No Spotify Web API source.** `SpotifyWebAPISource` is pure Foundation and would port,
  but it depends on `SpotifyAuth` (CryptoKit, AppKit) and `LoopbackCallbackServer`
  (Network.framework). The local media-session source works today, needs no sign-in, and is
  *better* than its macOS counterpart. This matters less than it sounds: as the README
  notes, Spotify serves the Web API to five hand-allowlisted accounts, so it was never the
  path most users take.
* **No credential storage.** Windows Credential Manager is the intended replacement for
  Keychain, and is only needed once the Web API source lands. Nothing today handles a
  secret, which is why the "no token reaches a log" rule has nothing to guard yet.
* **Not code-signed.** No Authenticode certificate, so SmartScreen warns on first run.
  `release-windows.ps1` signs everything when given a thumbprint.
* **No `AppEnvironment` equivalent.** The tray application wires its own dependencies; there
  is no shared composition root between the two platforms.
* **Gate cases 4 and 5 from `ACCEPTANCE_TESTS.md`** — Teams window closed, and Teams quit
  and relaunched — are **not** implemented. Both are treated as unrecoverable (`noWindow`,
  `notRunning`) rather than repaired, because relaunching Teams is a visible action this app
  should not take unasked.
* **The Windows CI job has not run on a hosted runner.** The Swift version is pinned in an
  installer URL and the vcvars path assumes VS Enterprise on `windows-latest`; both may need
  adjusting on first run.
* **`PresenceSourceKind.spotifyLocal.summary` still reads "on this Mac"** — a shared string
  that renders verbatim in Windows UI.

### A cross-platform question this raises

Nothing stops the macOS and Windows apps running against the same Teams account at once,
and during development both were writing. Teams accepts it — last write wins — but the two
instances will fight over the status. Worth deciding deliberately before shipping Windows.

---

## 13. Notes for reviewers

* `PresenceSourceKind.spotifyLocal.summary` reads *"Reads the Spotify app on this Mac
  only"*. That string lives in a shared portable file and will render verbatim in any
  Windows UI. Left unchanged here rather than edited in passing.
* `UnicodeSanitizer`'s doc comment explains the astral substitution in terms of `CGEvent`,
  which is a macOS-specific justification for behaviour that now runs on both platforms.
  See the open question in [§5](#5-entering-text).
* Everything in `CTeamsWin` returns "delivered", never "succeeded". The verification rule
  is enforced on the Swift side; the C layer is shaped so it *cannot* be the thing that
  claims success.
