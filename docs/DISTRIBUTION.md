# Distribution

How a release of Teams Music Status is built, signed, notarized and packaged.

This is for whoever cuts a release. Users want the [README](../README.md).

---

## What ships

| | |
|---|---|
| Artifact | `Teams-Music-Status-<version>-macOS.dmg` |
| Contents | `Teams Music Status.app` + an `Applications` alias |
| Architectures | Universal 2 — `arm64` + `x86_64` |
| Minimum macOS | 14.0 (Sonoma) — set by `platforms:` in `Package.swift` |
| Bundle identifier | `com.zanderdent.TeamsMusicStatus` |
| Signing | Developer ID Application, hardened runtime, secure timestamp |
| Notarization | Apple notary service, ticket stapled to the DMG |

The deployment target is asserted at build time: `release.sh` fails if
`Package.swift` and `scripts/common.sh` disagree, so the DMG can never claim wider
compatibility than the binary has.

---

## One command

```sh
./scripts/release.sh --notarize
```

| Mode | What it does | Distributable? |
|---|---|---|
| `--unsigned` | builds and packages, no signature | **No** — local testing only |
| `--dev-signed` | signs with an Apple Development certificate | **No** — see below |
| `--signed` | requires a Developer ID Application certificate | Not until notarized |
| `--notarize` | `--signed` plus notarize and staple | **Yes** |
| *(no flag)* | signs with Developer ID if one exists, else unsigned | depends |

Other flags: `--arch arm64|x86_64|universal` (default universal), `--skip-tests`
(packaging iteration only — never for a real release).

### Why `--dev-signed` exists and is not a release

An **Apple Development** certificate can sign a bundle and enable the hardened runtime,
so it is useful for proving that signing does not break the app. It **cannot be
notarized**, and Gatekeeper rejects the result on any Mac other than the one that built
it. It is a separate mode from `--signed` precisely so a development artifact can never
be mistaken for, or accidentally published as, a release.

> **A development-signed build publishes the signer's Apple ID email.** An Apple
> Development certificate's common name is `Apple Development: <apple-id-email> (TEAMID)`,
> and it is embedded in the signature for anyone who obtains the artifact:
>
> ```sh
> codesign -dvvv "Teams Music Status.app"   # Authority=Apple Development: you@example.com
> ```
>
> A Developer ID certificate carries the *team* name instead. One more reason
> `--dev-signed` output must never be published.

Do not confuse the three certificate types:

| Certificate | Purpose | Notarizable |
|---|---|---|
| Apple Development | local development and testing | No |
| Mac App Distribution | Mac App Store submission | No (different pipeline) |
| **Developer ID Application** | **direct download outside the App Store** | **Yes** |

---

## The pipeline

```
preflight   deployment target, icon, entitlements, client ID, git state
  ↓
identity    discover Developer ID; refuse to guess between several
  ↓
clean       reset dist/stage
  ↓
test        swift test — a failure stops the release
  ↓
build       arm64 and x86_64 slices, then lipo into Universal 2
  ↓
assemble    Info.plist, icon, PkgInfo; strip symbols
  ↓
sign        nested code first, then the app; hardened runtime + timestamp
  ↓
verify      codesign --verify --deep --strict, entitlements ON THE SIGNED BUNDLE,
            hardened runtime flag, LSUIElement, bundle identifier
  ↓
package     DMG with an Applications alias and a Finder layout
  ↓
notarize    xcrun notarytool submit --wait; fetches the log and stops on rejection
  ↓
staple      xcrun stapler staple + validate — the DMG then works offline
  ↓
assess      spctl Gatekeeper assessment
  ↓
publish     SHA-256 + dist/release-info.txt
```

Every step fails loudly. Nothing reports success it has not observed.

---

## Prerequisites

### 1. Developer ID Application certificate

Requires a paid **Apple Developer Program** membership ($99/year). A free Apple ID gets
Apple Development certificates only, which cannot be notarized.

1. <https://developer.apple.com/account> → Certificates, Identifiers & Profiles
2. **Certificates** → **+** → **Developer ID Application**
3. Follow the Certificate Signing Request steps, download the `.cer`, double-click it
4. Confirm:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

If several exist, pin one rather than letting the script guess:

```sh
export DEVELOPER_ID_APPLICATION="ABCDEF1234567890ABCDEF1234567890ABCDEF12"   # SHA-1
```

Prefer the SHA-1 hash over the name: the same certificate name can exist in more than
one keychain, and `codesign` then fails with "ambiguous".

### 2. Notarization credentials

Stored in your Keychain, never in this repository:

```sh
xcrun notarytool store-credentials "teams-music-status" \
  --apple-id "you@example.com" \
  --team-id "YOURTEAMID" \
  --password "abcd-efgh-ijkl-mnop"
```

The password is an **app-specific password**, not your Apple ID password. Create one at
<https://account.apple.com> → Sign-In and Security → App-Specific Passwords.

Override the profile name with `NOTARY_PROFILE` if you use a different one.

> Never put an Apple ID password, app-specific password, API key or `.p12` into the
> repository, a CI secret, an environment file, or a chat message.

### 3. Spotify client ID

The release needs one, and `release.sh` refuses to build a signed artifact without it —
shipping an app whose "Connect Spotify" button cannot work is worse than not shipping.

Resolution order:

1. `SPOTIFY_CLIENT_ID` in the environment
2. `Config/Spotify.plist` → `ClientID` key *(git-ignored)*
3. `.env` → `SPOTIFY_CLIENT_ID=…` *(git-ignored)*

```sh
mkdir -p Config
/usr/libexec/PlistBuddy -c 'Add :ClientID string <your client id>' Config/Spotify.plist
```

**Why the client ID is safe to ship and the secret is not.** OAuth 2.0 with PKCE exists
so a desktop app does not need a secret; the client ID is public by design and is visible
in the authorization URL anyway. A shipped *secret* would be extractable from the bundle
in seconds, which is why this app has none and the code has no path that could use one.

The ID is sourced from git-ignored files rather than the repo so a fork does not inherit
someone else's registration, and so the repository can be public without publishing
unrelated configuration. Contributors register their own free Spotify app — see the
README.

---

## Entitlements

Exactly one, in `scripts/TeamsMusicStatus.entitlements`:

```xml
<key>com.apple.security.automation.apple-events</key><true/>
```

**Why it is required.** The app is signed with the hardened runtime, which blocks Apple
Events unless this entitlement is present. Without it macOS refuses every event with
`-1743` and *never shows a consent prompt*, which is indistinguishable from the user
having denied Automation access. That breaks the Local Spotify source and the AppleScript
fallback that reopens a closed Teams window.

**Nothing else is needed.** Accessibility is gated by TCC, not by an entitlement. There
is no App Sandbox: this is a direct-download app, and sandboxing would prevent the
Accessibility automation the product is built on. No sandbox entitlements, no
`disable-library-validation`, no App Store keys.

> ### Two traps that fail silently
>
> **The entitlements file must be bare XML with no comments.** `codesign` hands it to
> AMFI, whose parser is stricter than `plutil` and fails on a comment block with
> `AMFIUnserializeXML: syntax error`. It then signs the app with **no entitlements at
> all** and reports success. `release.sh` rejects a commented file up front.
>
> **Verify entitlements on the signed bundle, never on the source file:**
>
> ```sh
> codesign -d --entitlements :- "dist/stage/Teams Music Status.app"
> ```
>
> `release.sh` does this and aborts if the apple-events entitlement is absent.

---

## Verifying a release by hand

```sh
APP="dist/stage/Teams Music Status.app"

codesign --verify --deep --strict --verbose=4 "$APP"   # structure and seal
codesign -dv --verbose=4 "$APP"                        # authority, team, flags=(runtime)
codesign -d --entitlements :- "$APP"                   # what actually got signed in
spctl --assess --type execute --verbose=4 "$APP"       # Gatekeeper verdict
xcrun stapler validate dist/Teams-Music-Status-*.dmg   # ticket present for offline use
```

A properly released app reports `accepted` with `source=Notarized Developer ID`.
`rejected` with `source=no usable signature` means unsigned; `Unnotarized Developer ID`
means signed but not notarized.

### The strongest test: pretend to be a stranger

```sh
cp dist/Teams-Music-Status-1.0.1-macOS.dmg /tmp/
xattr -w com.apple.quarantine "0083;$(printf %x $(date +%s));Safari;$(uuidgen)" \
  /tmp/Teams-Music-Status-1.0.1-macOS.dmg
open /tmp/Teams-Music-Status-1.0.1-macOS.dmg
```

Drag the app to Applications and launch it. A notarized build opens normally. An
un-notarized one shows *"cannot be opened because the developer cannot be verified"*.

---

## Bumping the version

`VERSION` is the only place these live. Nothing else may hardcode them.

```
MARKETING_VERSION=1.0.1
BUILD_NUMBER=2
```

`BUILD_NUMBER` must increase for **every** artifact you publish, even a rebuild of the
same marketing version. Commit the bump, then run the release — `release.sh` warns when
the working tree is dirty, because that release would not be reproducible from git.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `No "Developer ID Application" certificate is installed` | You have an Apple Development certificate, which cannot be notarized. See Prerequisites 1. |
| `ambiguous (matches "…" in …)` | The same certificate name exists in two keychains. Set `DEVELOPER_ID_APPLICATION` to the SHA-1 hash. |
| `multiple Developer ID Application identities found` | Intentional: the script will not guess. Pin one. |
| `signed bundle is MISSING com.apple.security.automation.apple-events` | The entitlements file was ignored — almost always an XML comment in it. |
| `hardened runtime is not enabled` | Signing lost `--options runtime`. Note that piping `codesign` into `grep -q` under `set -o pipefail` produces this error *spuriously*; the script captures output to a variable instead. |
| Notarization `Invalid` | The script fetches the log automatically. Usually an unsigned nested binary, a missing secure timestamp, or the hardened runtime being off. |
| Notarization hangs | Apple's service can queue for minutes. `--wait` is doing its job; check `xcrun notarytool history --keychain-profile teams-music-status`. |
| `could not set the Finder layout` | The DMG cosmetics need Automation permission for Finder. Harmless — the DMG is valid, just plainly laid out. |
| Gatekeeper still rejects after notarizing | The ticket was not stapled, or you assessed the staging copy rather than the one from the DMG. |
| App launches but "Connect Spotify" is greyed out | No client ID reached the bundle. Check `Config/Spotify.plist`. |
| Accessibility permission asked for again after an update | Expected when the signing identity changes: macOS keys the grant to the code signature. It is stable across rebuilds with the *same* certificate. |

---

## Release checklist

- [ ] `VERSION` bumped and committed
- [ ] `swift test` green
- [ ] `./scripts/release.sh --notarize` completes with **Accepted**
- [ ] `xcrun stapler validate` passes on the DMG
- [ ] `spctl --assess` reports `accepted … Notarized Developer ID`
- [ ] Quarantined download test on a clean path opens without warnings
- [ ] `dist/release-info.txt` and the `.sha256` reviewed
- [ ] `dist/RELEASE_NOTES.md` updated
- [ ] No secret anywhere in the repo or the bundle
- [ ] `codesign -dvvv` on the artifact shows a **Developer ID** authority, not
      `Apple Development: <email>` — the latter publishes the signer's Apple ID
- [ ] Attach the DMG, the `.sha256` and the notes to a GitHub Release
