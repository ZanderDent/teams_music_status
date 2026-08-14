## What this changes

<!-- One or two sentences. Link the issue if there is one. -->

## Why

<!-- The problem being solved. If the fix looks arbitrary, say what you measured. -->

## Testing

```
$ swift test
$ swift run trpctl selftest
$ swift run trpctl gate
```

<!-- Paste the gate result line, including whether focus was preserved. -->

- Tested on macOS: <!-- e.g. 15.3.1 -->
- Tested against Teams: <!-- e.g. 26198.202.4929.7171 -->
- Acceptance sections run (if sync behaviour changed): <!-- e.g. E, F, G -->

## Checklist

- [ ] No screen coordinates, `AXPosition`, `AXFrame` or pixel matching
- [ ] Every new interaction verifies an observable state transition, not `AXError.success`
- [ ] The frontmost application is unchanged during automation
- [ ] No token, authorization code or PKCE verifier can reach a log
- [ ] New Teams UI knowledge lives in `TeamsSelectors` and is covered by the self-test
- [ ] Unit tests added or updated for logic changes
