// set_status.swift — Experiment B5: end-to-end programmatic change of the Microsoft
// Teams custom status message, using only semantic AXUIElement selectors.
//
// NO screen coordinates are used anywhere in this file.
//
// Build: swiftc -O set_status.swift -o set_status
//
// Usage:
//   ./set_status --get                       read current status message, change nothing
//   ./set_status "♪ Dreams — Fleetwood Mac"  set the status message
//   ./set_status "text" --clear-after "1 hour"
//   ./set_status --clear                     delete the status message
//
// Flow:  profile button -> (Edit|Set) status message -> compose box -> type -> Done
import AppKit
import ApplicationServices

let BUNDLE = "com.microsoft.teams2"
let COMPOSE_DOM_ID = "status-note-compose"

// ───────────────────────────── AX plumbing ─────────────────────────────
func raw(_ el: AXUIElement, _ n: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, n as CFString, &v) == .success ? v : nil
}
func str(_ el: AXUIElement, _ n: String) -> String? {
    guard let v = raw(el, n) else { return nil }
    if let s = v as? String { return s }
    if let num = v as? NSNumber { return num.stringValue }
    return nil
}
func kids(_ el: AXUIElement) -> [AXUIElement] {
    (raw(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}
func press(_ el: AXUIElement) -> Bool {
    AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
}

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: BUNDLE).first else {
    FileHandle.standardError.write("ERROR: Microsoft Teams is not running\n".data(using: .utf8)!)
    exit(10)
}
let appPid = app.processIdentifier
let axApp = AXUIElementCreateApplication(appPid)

/// Deliver a key event to the Teams process without activating it.
func sendKey(_ key: CGKeyCode, flags: CGEventFlags = [], to pid: pid_t) {
    guard let src = CGEventSource(stateID: .privateState) else { return }
    for down in [true, false] {
        if let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) {
            e.flags = flags
            e.postToPid(pid)
        }
    }
}

/// Activate a control and CONFIRM it did something.
///
/// Chromium inside Teams often returns .success from AXPress while never running the
/// DOM click handler — the call is a no-op that reports success. So every activation
/// is verified against an observable effect, and falls back to focusing the element
/// (AXFocused, semantic — no coordinates) and delivering a real Return key event,
/// which Chromium routes through its normal keyboard-activation path.
func activate(_ el: AXUIElement, expect: @escaping () -> Bool,
              label: String, timeout: Double = 4.0) -> Bool {
    func settle() -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if expect() { return true }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return false
    }
    if press(el), settle() { return true }

    // Checkboxes activate on Space in Chromium's keyboard model, buttons on Return.
    // Try the role-appropriate key first, then the other one.
    var r: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r)
    let isCheckbox = (r as? String) == "AXCheckBox"
    let keys: [(CGKeyCode, String)] = isCheckbox
        ? [(49, "Space"), (36, "Return")]
        : [(36, "Return"), (49, "Space")]

    for (key, name) in keys {
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.3)
        sendKey(key, to: appPid)
        if settle() { print("   (\(label): AXPress no-op, \(name) fallback worked)"); return true }
    }

    print("   (\(label): AXPress, Return and Space all failed)")
    return false
}


/// Depth-first search over the Teams AX tree.
func first(where match: (AXUIElement) -> Bool, maxDepth: Int = 40) -> AXUIElement? {
    var hit: AXUIElement?
    func walk(_ el: AXUIElement, _ d: Int) {
        if hit != nil || d > maxDepth { return }
        if match(el) { hit = el; return }
        for c in kids(el) { walk(c, d + 1) }
    }
    walk(axApp, 0)
    return hit
}
func waitFor(_ label: String, timeout: Double = 6.0,
             _ match: @escaping (AXUIElement) -> Bool) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let e = first(where: match) { return e }
        Thread.sleep(forTimeInterval: 0.15)
    }
    FileHandle.standardError.write("TIMEOUT waiting for \(label)\n".data(using: .utf8)!)
    return nil
}

func role(_ el: AXUIElement) -> String { str(el, kAXRoleAttribute as String) ?? "" }
func desc(_ el: AXUIElement) -> String { str(el, kAXDescriptionAttribute as String) ?? "" }
func title(_ el: AXUIElement) -> String { str(el, kAXTitleAttribute as String) ?? "" }

// ─────────────────────── semantic element locators ─────────────────────
// Each locator is expressed as role + a stable accessible name/DOM id, never a
// child-index path, so ordinary Teams UI reshuffles do not break them.
let profileButton = { first { role($0) == "AXButton" && desc($0).hasPrefix("Your profile") } }
let statusReadout = { first { role($0) == "AXTextField" && desc($0).hasPrefix("Your current status message") } }
let editStatusBtn = { first { role($0) == "AXButton" && desc($0) == "Edit status message" } }
let deleteStatusBtn = { first { role($0) == "AXButton" && desc($0) == "Delete status message" } }
let setStatusItem = { first { ["AXMenuItem", "AXButton"].contains(role($0))
                              && (desc($0).localizedCaseInsensitiveContains("set status message")
                                  || title($0).localizedCaseInsensitiveContains("set status message")) } }
let composeBox = { first { str($0, "AXDOMIdentifier") == COMPOSE_DOM_ID
                           || (role($0) == "AXTextArea"
                               && desc($0).contains("mention someone in your status")) } }
let doneButton = { first { role($0) == "AXButton" && title($0) == "Done" } }
let showWhenMessagedBox = { first { role($0) == "AXCheckBox" && title($0) == "Show when people message me" } }
let clearAfterPopup = { first { role($0) == "AXPopUpButton" && title($0).hasPrefix("Clear status message after") } }

// ───────────────────── typing (no coordinates, no focus theft) ─────────
// AXFocused places the caret; CGEventPostToPid delivers key events to the Teams
// process only, so the user's frontmost application never changes.
//
// KNOWN LIMIT: astral-plane emoji (🎵 U+1F3B5, a UTF-16 surrogate pair) are dropped
// by Chromium's synthetic-event path. BMP symbols (♪ U+266A, ♫ U+266B) insert fine.
func typeReplacing(_ field: AXUIElement, with text: String) {
    AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.25)
    let pid = app.processIdentifier
    guard let src = CGEventSource(stateID: .privateState) else { return }

    func post(_ key: CGKeyCode, flags: CGEventFlags = [], unicode: [UniChar]? = nil) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
            e.flags = flags
            if var u = unicode { e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u) }
            e.postToPid(pid)
        }
    }

    post(0, flags: .maskCommand)          // ⌘A select all
    Thread.sleep(forTimeInterval: 0.12)
    post(51)                              // Delete  (flags MUST be cleared, see settext.swift)
    Thread.sleep(forTimeInterval: 0.12)
    for ch in text {                      // one grapheme per event
        post(0, unicode: Array(String(ch).utf16))
        Thread.sleep(forTimeInterval: 0.012)
    }
    Thread.sleep(forTimeInterval: 0.35)
}

/// Chromium's synthetic-event path silently drops astral-plane scalars (> U+FFFF),
/// so emoji would vanish mid-string. Substitute a visually equivalent BMP symbol
/// where one exists and drop the rest, then tidy the whitespace that dropping leaves.
let ASTRAL_FALLBACK: [UnicodeScalar: String] = [
    "\u{1F3B5}": "\u{266A}",   // 🎵 -> ♪
    "\u{1F3B6}": "\u{266B}",   // 🎶 -> ♫
    "\u{1F3A7}": "\u{266A}",   // 🎧 -> ♪
    "\u{25B6}":  "\u{25B6}",   // ▶ is already BMP
]
func sanitize(_ s: String) -> String {
    var out = ""
    for u in s.unicodeScalars {
        if u.value <= 0xFFFF { out.unicodeScalars.append(u) }
        else if let sub = ASTRAL_FALLBACK[u] { out += sub }
    }
    while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
    return out.trimmingCharacters(in: .whitespaces)
}

// ─────────────────────────── flyout state machine ──────────────────────
func openProfileFlyout() -> Bool {
    if statusReadout() != nil || composeBox() != nil || setStatusItem() != nil { return true }
    guard let btn = profileButton() else { print("ERROR: profile button not found"); return false }
    return activate(btn, expect: {
        statusReadout() != nil || setStatusItem() != nil || composeBox() != nil
    }, label: "profile button", timeout: 6.0)
}

func closeFlyout() {
    // Escape unwinds the flyout without committing anything further.
    guard let src = CGEventSource(stateID: .privateState) else { return }
    for down in [true, false] {
        if let e = CGEvent(keyboardEventSource: src, virtualKey: 53 /* kVK_Escape */, keyDown: down) {
            e.flags = []
            e.postToPid(app.processIdentifier)
        }
    }
    Thread.sleep(forTimeInterval: 0.4)
}

func readCurrentStatus() -> String? {
    guard openProfileFlyout() else { return nil }
    if let f = statusReadout() {
        return (str(f, kAXValueAttribute as String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return ""   // flyout open but no status set
}

// ──────────────────────────────── main ─────────────────────────────────
var args = Array(CommandLine.arguments.dropFirst())
let frontBefore = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
print("frontmost before: \(frontBefore)   (Teams active=\(app.isActive) hidden=\(app.isHidden))")

if args.first == "--get" {
    let s = readCurrentStatus()
    closeFlyout()
    print("STATUS: \(s.map { "\"\($0)\"" } ?? "<unreadable>")")
    print("frontmost after: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
    exit(s == nil ? 1 : 0)
}

if args.first == "--clear" {
    guard openProfileFlyout() else { exit(2) }
    guard let del = deleteStatusBtn() else { print("no status to delete"); closeFlyout(); exit(0) }
    _ = press(del)
    Thread.sleep(forTimeInterval: 0.8)
    closeFlyout()
    print("cleared.")
    print("frontmost after: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
    exit(0)
}

guard let rawText = args.first, !rawText.hasPrefix("--") else {
    print("usage: set_status \"<message>\" [--clear-after <label>] | --get | --clear"); exit(2)
}
let text = sanitize(rawText)
if text != rawText { print("NOTE: text rewritten for BMP-only injection: \"\(rawText)\" -> \"\(text)\"") }

var clearAfter: String?
if let i = args.firstIndex(of: "--clear-after"), i + 1 < args.count { clearAfter = args[i + 1] }

guard openProfileFlyout() else { exit(2) }
let previous = statusReadout().map { (str($0, kAXValueAttribute as String) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
print("previous status: \"\(previous)\"")

// Enter the editor: "Edit status message" when one exists, otherwise the
// "Set status message" flyout item.
if composeBox() == nil {
    if let edit = editStatusBtn() {
        _ = activate(edit, expect: { composeBox() != nil }, label: "Edit status message")
    } else if let setItem = setStatusItem() {
        _ = activate(setItem, expect: { composeBox() != nil }, label: "Set status message")
    } else {
        print("ERROR: neither 'Edit status message' nor 'Set status message' found"); exit(3)
    }
}
guard let box = waitFor("compose box", { el in
    str(el, "AXDOMIdentifier") == COMPOSE_DOM_ID
    || (role(el) == "AXTextArea" && desc(el).contains("mention someone in your status"))
}) else { exit(3) }
print("compose box located via AXDOMIdentifier=\(COMPOSE_DOM_ID)")

typeReplacing(box, with: text)
let typed = composeBox().flatMap { str($0, kAXValueAttribute as String) } ?? ""
print("compose box now: \"\(typed)\"")

// "Show when people message me" — surfaces the status above the compose box in a
// 1:1 chat. Checked by default; --no-show-when-messaged opts out. AXCheckBox exposes
// AXValue as "0"/"1" and toggles via AXPress, so this is a read-then-press, never a
// blind toggle.
let wantShow = !args.contains("--no-show-when-messaged")
if let cb = showWhenMessagedBox() {
    // In a healthy a11y tree this reports "0"/"1". In the force-enabled tree it can
    // come back as an empty string — state is then unknown, and a blind toggle could
    // just as easily turn the setting off. Read first; only act when the state is
    // legible, and say so plainly when it is not.
    let rawVal = str(cb, kAXValueAttribute as String) ?? ""
    let known = rawVal == "0" || rawVal == "1"
    if !known {
        print("'Show when people message me': state UNREADABLE (AXValue=\"\(rawVal)\") — " +
              "skipping rather than blind-toggling; see FEASIBILITY.md 'degraded tree'")
    } else {
        let isOn = rawVal == "1"
        print("'Show when people message me' currently \(isOn ? "checked" : "unchecked"), want \(wantShow ? "checked" : "unchecked")")
        if isOn != wantShow {
            let ok = activate(cb, expect: {
                (showWhenMessagedBox().flatMap { str($0, kAXValueAttribute as String) } ?? "") == (wantShow ? "1" : "0")
            }, label: "show-when-messaged checkbox")
            let now = showWhenMessagedBox().flatMap { str($0, kAXValueAttribute as String) } ?? "?"
            print("  toggled -> AXValue=\(now) \(ok ? "✅" : "❌")")
        }
    }
} else {
    print("WARN: 'Show when people message me' checkbox not found")
}

// Clear duration. Options observed on Teams 26183: Never / Today / 1 hour /
// 4 hours / This week / Custom. The popup itself needs the same verified activation
// as every other control — a raw AXPress reports success without opening it.
func clearOption(_ want: String) -> AXUIElement? {
    first { ["AXMenuItem", "AXRadioButton", "AXStaticText", "AXButton"].contains(role($0))
            && (title($0) == want || desc($0) == want
                || (str($0, kAXValueAttribute as String) ?? "") == want) }
}
if let want = clearAfter, let popup = clearAfterPopup() {
    print("clear-after popup: \"\(title(popup))\" -> requesting \"\(want)\"")
    if activate(popup, expect: { clearOption(want) != nil }, label: "clear-after popup") {
        if let opt = clearOption(want) {
            _ = activate(opt, expect: {
                clearAfterPopup().map { title($0).hasSuffix(want) } ?? false
            }, label: "clear-after option \(want)")
            print("clear-after now: \(clearAfterPopup().map { title($0) } ?? "?")")
        }
    } else {
        print("WARN: could not open the clear-after popup / option \"\(want)\" never appeared")
    }
}

guard let done = doneButton() else { print("ERROR: Done button not found"); exit(4) }
guard activate(done, expect: { composeBox() == nil }, label: "Done", timeout: 5.0) else {
    print("ERROR: could not activate Done"); exit(4)
}
print("committed via Done")
Thread.sleep(forTimeInterval: 1.2)

// Verify by re-reading the flyout's status readout.
let after = statusReadout().map { (str($0, kAXValueAttribute as String) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines) }
print("status readout after commit: \(after.map { "\"\($0)\"" } ?? "<flyout closed>")")
closeFlyout()

let frontAfter = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
print("frontmost after: \(frontAfter)  -> focus \(frontBefore == frontAfter ? "PRESERVED ✅" : "STOLEN ❌")")
// The readout appends a second line ("Display until 8:27 AM") whenever a clear
// duration is set, so only the first line is the status message itself.
if let a = after {
    let firstLine = a.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? a
    exit(firstLine.trimmingCharacters(in: .whitespaces) == text ? 0 : 5)
}
exit(0)
