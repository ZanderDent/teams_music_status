# Contributing

Thanks for taking a look. This is a small utility with one unusual property: most of its
risk lives in a UI it does not control. That shapes how it is built and reviewed.

## Getting set up

```sh
export SPOTIFY_CLIENT_ID=your_client_id   # see README for how to get one
swift build && swift test                 # no Teams or Spotify needed
./scripts/build-app.sh --run              # build and launch the real app
```

### On Windows

The Windows build shares `TeamsMusicStatusCore` with macOS and adds its own target and
presence source. Setup, the measured findings behind the design, and what is not done yet
are in [`docs/WINDOWS.md`](docs/WINDOWS.md).

```powershell
winget install Microsoft.VisualStudio.2022.BuildTools   # MSVC + Windows SDK
winget install Swift.Toolchain
# then import the MSVC environment and restore SDKROOT — see docs/WINDOWS.md §10
swift build && swift test
```

## Ground rules

**No screen coordinates. Ever.** No `AXPosition`, no `AXFrame`, no pixel matching, no
image recognition. Navigation is by `AXDOMIdentifier` or accessible name only. A patch
that clicks a point will not be merged.

**Never treat `AXError.success` as proof.** Chromium accepts operations it then discards.
Every interaction must observe the state transition it expected and fail loudly if it did
not happen. Use `AXActivator.activate(_:expecting:)` rather than calling `AXPress`
directly.

**Never steal focus.** Key events go to the Teams pid via `CGEvent.postToPid`. Window
repair uses non-activating APIs. If you add an interaction, prove the frontmost app is
unchanged — `tmsctl gate` asserts this for you.

**Never log a secret.** Access tokens, refresh tokens, authorization codes, PKCE
verifiers and client secrets must not reach a logger, not even at debug level. Use
`Redact.secret`, which prints a length.

**Keep Teams knowledge in one file.** Anything about how the Teams UI is shaped belongs
in `TeamsSelectors`, with a matching entry in the self-test.

### The same rules on Windows

Every rule above holds; only the API names change. The Windows equivalents were arrived at
by measurement, and in each case the *obvious* choice is the one that fails — see
[`docs/WINDOWS.md`](docs/WINDOWS.md).

| Rule | macOS | Windows |
|---|---|---|
| No screen coordinates | no `AXPosition`/`AXFrame`/`AXSize` | no `BoundingRectangle`, no `GetClickablePoint`, no `SendInput` at a point |
| Success is never proof | `AXError.success` means nothing | neither does a UIA `HRESULT`. `ExpandCollapseState` reports `Collapsed` while the flyout is open, and `ValuePattern.SetValue` returns success without changing the field |
| Never steal focus | `CGEvent.postToPid` | `PostMessage` to `Chrome_WidgetWin_1`. **Never** UIA `SetFocus` or `ExpandCollapsePattern.Expand` — both activate Teams |
| Activation | `AXActivator.activate(_:expecting:)` | MSAA `accDoDefaultAction`, navigated from `AccessibleObjectFromWindow`. UIA's `LegacyIAccessible` bridge does not work |
| Teams knowledge in one file | `TeamsSelectors` | the *same* `TeamsSelectors` — it is shared, not duplicated |

## How changes get merged

`main` is protected. Nobody pushes to it directly, including the maintainer's own work
going through review where practical:

* fork the repo, branch, and open a pull request;
* CI must pass — it builds, runs the tests, and fails the build if a credential is
  committed, an absolute developer path appears, a token becomes reachable by a logger,
  or the Teams automation starts reading screen geometry;
* the maintainer (listed in `.github/CODEOWNERS`) must approve;
* force-pushes and branch deletion are blocked, so history cannot be rewritten or wiped.

## Before opening a pull request

```sh
swift test                              # unit tests must pass
swift run tmsctl selftest               # selectors still resolve
swift run tmsctl gate                   # Teams automation still works end to end
```

On Windows the same three checks, through the Windows harness:

```powershell
swift test                                     # unit tests must pass
.\.build\debug\tmswinctl.exe teams-selectors   # selectors still resolve
.\.build\debug\tmswinctl.exe gate              # Teams automation still works end to end
```

Include in the description:

* the macOS (or Windows) and Teams versions you tested on;
* the `tmsctl gate` — or `tmswinctl gate` — result line, including whether focus was
  preserved;
* which sections of `docs/ACCEPTANCE_TESTS.md` you ran, if you touched sync behaviour.

## Reporting a bug

Please include:

```sh
swift run tmsctl version
swift run tmsctl health
swift run tmsctl selftest
```

If Teams updated recently, the self-test output usually identifies the problem outright.

For logs:

```sh
log show --predicate 'subsystem == "com.zanderdent.TeamsMusicStatus"' --last 30m --style compact
```

Read them before pasting — they contain your status text, which may be personal. They do
not contain credentials.

## Adding a new presence source

1. Conform to `PresenceSource` in `Sources/TeamsMusicStatusCore/Presence/<Name>/`.
2. Add a case to `PresenceSourceKind` with a `displayName` and an honest `summary`,
   including its limitations.
3. Wire it in `AppEnvironment`.
4. Add parsing tests. No coordinator changes should be needed — if they are, the
   abstraction is wrong and that is worth discussing first.

## Style

Match the surrounding code. Comments should explain *why*, especially where behaviour
looks arbitrary — most of the odd-looking code here is load-bearing and was arrived at by
measurement. If you remove something that looks redundant, check `docs/FEASIBILITY.md`
first; several no-op-looking calls are what make Chromium cooperate.
