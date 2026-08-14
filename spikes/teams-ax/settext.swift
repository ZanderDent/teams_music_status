// settext.swift — Experiment B4: which write strategy actually mutates the
// Teams "Set status message" CKEditor 5 contenteditable?
//
// The field is NOT a plain text control: AXDOMClassList = [ck, ck-content,
// ck-editor__editable] and AXDOMIdentifier = "status-note-compose". CKEditor keeps
// its own document model, so a raw DOM/AXValue poke is dropped on the floor even
// though AXUIElementSetAttributeValue returns .success.
//
// Build: swiftc -O settext.swift -o settext
// Usage: ./settext <strategy> "<text>"      strategy = value | seltext | replacerange | keys
//        ./settext all "<text>"             try each in turn, report which stuck
//
// The status editor must already be open (see run_experiment.sh).
import AppKit
import ApplicationServices

let BUNDLE = "com.microsoft.teams2"
let DOM_ID = "status-note-compose"

func raw(_ el: AXUIElement, _ n: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, n as CFString, &v) == .success ? v : nil
}
func str(_ el: AXUIElement, _ n: String) -> String? { raw(el, n) as? String }
func children(_ el: AXUIElement) -> [AXUIElement] {
    (raw(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: BUNDLE).first else {
    print("Teams not running"); exit(1)
}
let axApp = AXUIElementCreateApplication(app.processIdentifier)

/// Locate the compose box semantically: AXDOMIdentifier is the most stable handle,
/// with role+placeholder as fallback if Microsoft renames the DOM id.
func findCompose() -> AXUIElement? {
    var found: AXUIElement?
    func walk(_ el: AXUIElement, _ d: Int) {
        if found != nil || d > 40 { return }
        if str(el, "AXDOMIdentifier") == DOM_ID { found = el; return }
        if found == nil, str(el, kAXRoleAttribute as String) == "AXTextArea",
           (str(el, kAXPlaceholderValueAttribute as String) ?? "").contains("mention someone in your status") {
            found = el; return
        }
        for c in children(el) { walk(c, d + 1) }
    }
    walk(axApp, 0)
    return found
}

guard let field = findCompose() else {
    print("FAIL: status compose field not found — is the 'Set status message' editor open?")
    exit(2)
}
let before = str(field, kAXValueAttribute as String) ?? ""
print("compose field found. AXValue before = \"\(before)\"")

func current() -> String { str(findCompose() ?? field, kAXValueAttribute as String) ?? "<gone>" }

// ── S1: plain AXValue set ───────────────────────────────────────────────
func s1(_ text: String) -> AXError {
    AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFTypeRef)
}

// ── S2: select-all via AXSelectedTextRange, then set AXSelectedText ─────
func s2(_ text: String) -> AXError {
    let n = (raw(field, "AXNumberOfCharacters") as? NSNumber)?.intValue ?? before.count
    var range = CFRange(location: 0, length: n)
    if let rv = AXValueCreate(.cfRange, &range) {
        AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, rv)
    }
    return AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
}

// ── S3: AXReplaceRangeWithText parameterized attribute ──────────────────
func s3(_ text: String) -> AXError {
    let n = (raw(field, "AXNumberOfCharacters") as? NSNumber)?.intValue ?? before.count
    var range = CFRange(location: 0, length: n)
    guard let rv = AXValueCreate(.cfRange, &range) else { return .failure }
    let param: [String: Any] = ["AXValue": rv, "AXReplacementString": text]
    var out: CFTypeRef?
    return AXUIElementCopyParameterizedAttributeValue(
        field, "AXReplaceRangeWithText" as CFString, param as CFTypeRef, &out)
}

// ── S4: real key events delivered to the Teams pid (no screen coordinates) ──
// AXFocused puts the caret in the field; CGEventPostToPid delivers keystrokes to
// that process only, so the frontmost app never changes.
func s4(_ text: String) -> AXError {
    AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.25)
    let pid = app.processIdentifier
    guard let src = CGEventSource(stateID: .privateState) else { return .failure }

    // ⌘A — select existing content
    let aKey: CGKeyCode = 0 // kVK_ANSI_A
    for down in [true, false] {
        if let e = CGEvent(keyboardEventSource: src, virtualKey: aKey, keyDown: down) {
            e.flags = .maskCommand
            e.postToPid(pid)
        }
    }
    Thread.sleep(forTimeInterval: 0.12)

    // Delete — clear the selection (CKEditor needs a real deletion event).
    // NOTE: flags must be explicitly zeroed. The private event source latches the
    // Command modifier from the ⌘A above; if it leaks into these events Chromium
    // reads them as shortcuts and inserts nothing.
    for down in [true, false] {
        if let e = CGEvent(keyboardEventSource: src, virtualKey: 51 /* kVK_Delete */, keyDown: down) {
            e.flags = []
            e.postToPid(pid)
        }
    }
    Thread.sleep(forTimeInterval: 0.12)

    // Type the replacement one grapheme at a time as a unicode string.
    // virtualKey 0 + keyboardSetUnicodeString means no keymap dependency, so emoji
    // and any non-ASCII artist name work identically.
    for ch in text {
        var units = Array(String(ch).utf16)
        for down in [true, false] {
            if let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) {
                e.flags = []
                e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                e.postToPid(pid)
            }
        }
        Thread.sleep(forTimeInterval: 0.012)
    }
    Thread.sleep(forTimeInterval: 0.6)
    return .success
}

// ── S5: same as S4 but the whole string in ONE unicode event ───────────
// Per-character posting drops astral-plane emoji (🎵 = surrogate pair); sending the
// full UTF-16 buffer in a single event keeps the pair intact.
func s5(_ text: String) -> AXError {
    AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.25)
    let pid = app.processIdentifier
    guard let src = CGEventSource(stateID: .privateState) else { return .failure }
    for down in [true, false] {
        if let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) {
            e.flags = .maskCommand; e.postToPid(pid)
        }
    }
    Thread.sleep(forTimeInterval: 0.12)
    for down in [true, false] {
        if let e = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: down) {
            e.flags = []; e.postToPid(pid)
        }
    }
    Thread.sleep(forTimeInterval: 0.12)
    var units = Array(text.utf16)
    for down in [true, false] {
        if let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) {
            e.flags = []
            e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            e.postToPid(pid)
        }
    }
    Thread.sleep(forTimeInterval: 0.6)
    return .success
}

// ── S6: pasteboard + ⌘V ────────────────────────────────────────────────
// Most faithful to a real user edit (CKEditor handles a paste event natively) and
// immune to keymap/emoji issues, at the cost of touching the shared pasteboard.
// The previous contents are saved and restored.
func s6(_ text: String) -> AXError {
    let pb = NSPasteboard.general
    let saved = pb.string(forType: .string)
    pb.clearContents()
    pb.setString(text, forType: .string)

    AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.25)
    let pid = app.processIdentifier
    guard let src = CGEventSource(stateID: .privateState) else { return .failure }
    // ⌘A then ⌘V
    for key: CGKeyCode in [0 /* A */, 9 /* V */] {
        for down in [true, false] {
            if let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) {
                e.flags = .maskCommand; e.postToPid(pid)
            }
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    Thread.sleep(forTimeInterval: 0.6)
    if let saved { pb.clearContents(); pb.setString(saved, forType: .string) }
    return .success
}

// ── S7: pasteboard + AXPress on Teams' native Edit menu items ──────────
// Teams ships a real AppKit menu bar whose items carry stable AXIdentifiers
// (Select All = _NS:90, Paste = _NS:76) and are readable without opening the menu.
// AXPress on a menu item is a semantic activation, not a synthetic click, so this
// path needs no coordinates and no key events — and it carries emoji intact,
// because the text arrives via the pasteboard rather than a keymap.
func menuItem(_ menuTitle: String, _ itemTitle: String) -> AXUIElement? {
    guard let barRef = raw(axApp, kAXMenuBarAttribute as String) else { return nil }
    let bar = barRef as! AXUIElement
    for top in children(bar) where str(top, kAXTitleAttribute as String) == menuTitle {
        for menu in children(top) {
            for item in children(menu) where str(item, kAXTitleAttribute as String) == itemTitle {
                return item
            }
        }
    }
    return nil
}

func s7(_ text: String) -> AXError {
    let pb = NSPasteboard.general
    let saved = pb.string(forType: .string)
    pb.clearContents()
    pb.setString(text, forType: .string)
    defer { if let saved { pb.clearContents(); pb.setString(saved, forType: .string) } }

    AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.3)

    guard let selectAll = menuItem("Edit", "Select All"), let paste = menuItem("Edit", "Paste") else {
        print("   (Edit menu items not found)"); return .failure
    }
    let r1 = AXUIElementPerformAction(selectAll, kAXPressAction as CFString)
    Thread.sleep(forTimeInterval: 0.3)
    let r2 = AXUIElementPerformAction(paste, kAXPressAction as CFString)
    print("   SelectAll->\(r1.rawValue) Paste->\(r2.rawValue)")
    Thread.sleep(forTimeInterval: 0.7)
    return r2
}

let strategy = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "all"
let text = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "🎵 Teams Rich Presence test"

func attempt(_ name: String, _ fn: (String) -> AXError) {
    let pre = current()
    let err = fn(text)
    Thread.sleep(forTimeInterval: 0.4)
    let post = current()
    let stuck = post == text
    let call = err == .success ? "success" : "err\(err.rawValue)"
    let pad = name.padding(toLength: 16, withPad: " ", startingAt: 0)
    print("\(pad) call=\(call)  before=\"\(pre)\"  after=\"\(post)\"  -> \(stuck ? "TEXT CHANGED ✅" : "no effect ❌")")
    fflush(stdout)
}

switch strategy {
case "value":        attempt("AXValue", s1)
case "seltext":      attempt("AXSelectedText", s2)
case "replacerange": attempt("AXReplaceRange", s3)
case "keys":         attempt("CGEvent keys", s4)
case "keysbulk":     attempt("CGEvent bulk", s5)
case "paste":        attempt("Pasteboard ⌘V", s6)
case "menupaste":    attempt("Edit-menu paste", s7)
default:
    attempt("AXValue", s1)
    attempt("AXSelectedText", s2)
    attempt("AXReplaceRange", s3)
    attempt("CGEvent keys", s4)
}
print("final AXValue = \"\(current())\"")
