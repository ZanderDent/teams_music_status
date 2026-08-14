// teamsctl.swift — Experiment B3+: semantic AXUIElement driver for Microsoft Teams.
//
// No screen coordinates anywhere. Elements are located by (role, subrole, description,
// title, value, placeholder) predicates and addressed by child-index path only for
// re-resolution inside a single run.
//
// Build: swiftc -O teamsctl.swift -o teamsctl
//
// Subcommands:
//   tree [path] [depth]          print subtree
//   find <pred>...               search whole app tree, print matches + paths
//   waitfor <pred>... [--timeout S]
//   press <path|@pred>           AXPress
//   setval <path|@pred> <text>   set AXValue
//   focused                      print currently focused element
//   winfo                        window/app state (active, hidden, minimised, window count)
//
// Predicates:  role=AXButton  sub=AXToggleButton  desc~=Your profile  title~=Foo
//              value~=bar  placeholder~=Set status  desc==exact
import AppKit
import ApplicationServices

let BUNDLE = "com.microsoft.teams2"

// ───────────────────────── AX helpers ─────────────────────────
func raw(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}
func s(_ el: AXUIElement, _ name: String) -> String? {
    guard let v = raw(el, name) else { return nil }
    if let x = v as? String { return x }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}
func acts(_ el: AXUIElement) -> [String] {
    var a: CFArray?
    guard AXUIElementCopyActionNames(el, &a) == .success else { return [] }
    return (a as? [String]) ?? []
}
func children(_ el: AXUIElement) -> [AXUIElement] {
    (raw(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}
func describe(_ el: AXUIElement) -> String {
    var out = s(el, kAXRoleAttribute as String) ?? "?"
    if let x = s(el, kAXSubroleAttribute as String) { out += "[\(x)]" }
    for (label, key) in [("desc", kAXDescriptionAttribute as String),
                         ("title", kAXTitleAttribute as String),
                         ("value", kAXValueAttribute as String),
                         ("placeholder", kAXPlaceholderValueAttribute as String),
                         ("help", kAXHelpAttribute as String),
                         ("id", "AXIdentifier")] {
        if var v = s(el, key), !v.isEmpty {
            if v.count > 70 { v = String(v.prefix(70)) + "…" }
            out += " \(label)=\"\(v)\""
        }
    }
    let a = acts(el)
    if !a.isEmpty { out += " acts=\(a)" }
    return out
}

// ───────────────────────── app root ─────────────────────────
func appElement() -> AXUIElement? {
    guard let a = NSRunningApplication.runningApplications(withBundleIdentifier: BUNDLE).first else { return nil }
    return AXUIElementCreateApplication(a.processIdentifier)
}
func runningApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: BUNDLE).first
}

// resolve "/0/3/1" from root
func resolve(_ path: String) -> AXUIElement? {
    guard var cur = appElement() else { return nil }
    for comp in path.split(separator: "/") {
        guard let i = Int(comp) else { return nil }
        let kids = children(cur)
        guard i < kids.count else { return nil }
        cur = kids[i]
    }
    return cur
}

// ───────────────────────── predicates ─────────────────────────
struct Pred {
    var checks: [(AXUIElement) -> Bool] = []
    func matches(_ el: AXUIElement) -> Bool { checks.allSatisfy { $0(el) } }

    static func parse(_ args: [String]) -> Pred {
        var p = Pred()
        let keyMap = ["role": kAXRoleAttribute as String,
                      "sub": kAXSubroleAttribute as String,
                      "desc": kAXDescriptionAttribute as String,
                      "title": kAXTitleAttribute as String,
                      "value": kAXValueAttribute as String,
                      "placeholder": kAXPlaceholderValueAttribute as String,
                      "help": kAXHelpAttribute as String,
                      "id": "AXIdentifier"]
        for a in args {
            var exact = true, key = "", want = ""
            if let r = a.range(of: "~=") { exact = false; key = String(a[..<r.lowerBound]); want = String(a[r.upperBound...]) }
            else if let r = a.range(of: "==") { key = String(a[..<r.lowerBound]); want = String(a[r.upperBound...]) }
            else if let r = a.range(of: "=") { key = String(a[..<r.lowerBound]); want = String(a[r.upperBound...]) }
            else { continue }
            guard let axKey = keyMap[key] else { continue }
            p.checks.append { el in
                guard let got = s(el, axKey) else { return false }
                return exact ? got == want : got.localizedCaseInsensitiveContains(want)
            }
        }
        return p
    }
}

func search(_ pred: Pred, limit: Int = 50, maxDepth: Int = 40) -> [(String, AXUIElement)] {
    guard let root = appElement() else { return [] }
    var out: [(String, AXUIElement)] = []
    func walk(_ el: AXUIElement, _ path: String, _ d: Int) {
        if out.count >= limit { return }
        if pred.matches(el) { out.append((path, el)) }
        guard d < maxDepth else { return }
        for (i, k) in children(el).enumerated() { walk(k, "\(path)/\(i)", d + 1) }
    }
    walk(root, "", 0)
    return out
}

func target(_ spec: String) -> (String, AXUIElement)? {
    if spec.hasPrefix("@") {
        let preds = String(spec.dropFirst()).split(separator: ",").map(String.init)
        return search(Pred.parse(preds), limit: 1).first
    }
    guard let el = resolve(spec) else { return nil }
    return (spec, el)
}

// ───────────────────────── commands ─────────────────────────
var argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else {
    print("usage: teamsctl <tree|find|waitfor|press|setval|focused|winfo> ..."); exit(2)
}
argv.removeFirst()

guard appElement() != nil else { print("ERROR: Teams (\(BUNDLE)) not running"); exit(3) }

switch cmd {
case "winfo":
    let a = runningApp()!
    print("pid=\(a.processIdentifier) active=\(a.isActive) hidden=\(a.isHidden) terminated=\(a.isTerminated)")
    let root = appElement()!
    let wins = (raw(root, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    print("AXWindows=\(wins.count)")
    for (i, w) in wins.enumerated() {
        let mini = (raw(w, kAXMinimizedAttribute as String) as? NSNumber)?.boolValue ?? false
        print("  [\(i)] title=\(s(w, kAXTitleAttribute as String) ?? "<none>") minimized=\(mini) role=\(s(w, kAXRoleAttribute as String) ?? "?")")
    }
    if let f = raw(root, kAXFocusedUIElementAttribute as String) {
        print("focusedUIElement: \(describe(f as! AXUIElement))")
    }

case "tree":
    let path = argv.first.map { $0.hasPrefix("/") || $0.isEmpty ? $0 : "" } ?? ""
    let depth = Int(argv.count > 1 ? argv[1] : "10") ?? 10
    guard let root = resolve(path) else { print("bad path"); exit(4) }
    func walk(_ el: AXUIElement, _ p: String, _ d: Int) {
        print(String(repeating: "  ", count: d) + describe(el) + "  @\(p)")
        guard d < depth else { return }
        for (i, k) in children(el).enumerated() { walk(k, "\(p)/\(i)", d + 1) }
    }
    walk(root, path, 0)

case "find":
    let preds = argv.filter { !$0.hasPrefix("--") }
    let m = search(Pred.parse(preds))
    print("\(m.count) match(es)")
    for (p, el) in m { print("  \(describe(el))  @\(p)") }
    exit(m.isEmpty ? 1 : 0)

case "waitfor":
    var timeout = 5.0
    if let i = argv.firstIndex(of: "--timeout"), i + 1 < argv.count { timeout = Double(argv[i+1]) ?? 5.0 }
    let preds = argv.filter { !$0.hasPrefix("--") && Double($0) == nil }
    let pred = Pred.parse(preds)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let (p, el) = search(pred, limit: 1).first {
            print("FOUND \(describe(el))  @\(p)"); exit(0)
        }
        Thread.sleep(forTimeInterval: 0.15)
    }
    print("TIMEOUT after \(timeout)s"); exit(1)

case "press":
    guard let spec = argv.first, let (p, el) = target(spec) else { print("not found"); exit(4) }
    let action = argv.count > 1 ? argv[1] : kAXPressAction as String
    let r = AXUIElementPerformAction(el, action as CFString)
    print("\(action) @\(p) -> \(r == .success ? "success" : "err \(r.rawValue)")  [\(describe(el))]")
    exit(r == .success ? 0 : 5)

case "setval":
    guard argv.count >= 2, let (p, el) = target(argv[0]) else { print("not found"); exit(4) }
    let text = argv[1]
    let r = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef)
    print("setval @\(p) -> \(r == .success ? "success" : "err \(r.rawValue)")")
    if r == .success { print("   readback: \(s(el, kAXValueAttribute as String) ?? "<nil>")") }
    exit(r == .success ? 0 : 5)

case "activate":
    // Coordinate-free activation fallback for when Chromium accepts AXPress
    // (returns .success) but never runs the DOM click handler: focus the element
    // semantically, then deliver a real key event to the Teams process.
    // key defaults to Return (36); 49 = Space.
    guard let spec = argv.first, let (p, el) = target(spec) else { print("not found"); exit(4) }
    let key = CGKeyCode(UInt16(argv.count > 1 ? argv[1] : "36") ?? 36)
    let r = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    print("focus @\(p) -> \(r == .success ? "success" : "err \(r.rawValue)")")
    Thread.sleep(forTimeInterval: 0.35)
    guard let a = runningApp(), let src = CGEventSource(stateID: .privateState) else { exit(5) }
    for down in [true, false] {
        if let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) {
            e.flags = []
            e.postToPid(a.processIdentifier)
        }
    }
    print("sent key \(key) to pid \(a.processIdentifier)")
    Thread.sleep(forTimeInterval: 0.8)

case "attrs":
    // list every attribute on an element, its value, and whether AX reports it settable.
    guard let spec = argv.first, let (p, el) = target(spec) else { print("not found"); exit(4) }
    print("attrs @\(p)  \(describe(el))")
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(el, &names) == .success, let n = names as? [String] else {
        print("  <cannot enumerate>"); exit(5)
    }
    for name in n {
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, name as CFString, &settable)
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, name as CFString, &v)
        var vs = v.map { String(describing: $0) } ?? "<nil>"
        if vs.count > 80 { vs = String(vs.prefix(80)) + "…" }
        print("  \(settable.boolValue ? "RW" : "r ")  \(name) = \(vs)")
    }
    var pnames: CFArray?
    if AXUIElementCopyParameterizedAttributeNames(el, &pnames) == .success, let pn = pnames as? [String], !pn.isEmpty {
        print("  parameterized: \(pn)")
    }

case "setattr":
    // setattr <path|@pred> <AXAttributeName> <string|true|false|int>
    guard argv.count >= 3, let (p, el) = target(argv[0]) else { print("not found"); exit(4) }
    let name = argv[1], rawVal = argv[2]
    let value: CFTypeRef
    switch rawVal {
    case "true": value = kCFBooleanTrue
    case "false": value = kCFBooleanFalse
    default: value = Int(rawVal).map { $0 as CFTypeRef } ?? (rawVal as CFTypeRef)
    }
    let r = AXUIElementSetAttributeValue(el, name as CFString, value)
    print("setattr \(name) @\(p) -> \(r == .success ? "success" : "err \(r.rawValue)")")
    var back: CFTypeRef?
    AXUIElementCopyAttributeValue(el, name as CFString, &back)
    print("   readback \(name) = \(back.map { String(describing: $0) } ?? "<nil>")")
    print("   readback AXValue = \(s(el, kAXValueAttribute as String) ?? "<nil>")")
    exit(r == .success ? 0 : 5)

case "focused":
    let root = appElement()!
    guard let f = raw(root, kAXFocusedUIElementAttribute as String) else { print("<none>"); exit(1) }
    print(describe(f as! AXUIElement))

default:
    print("unknown command \(cmd)"); exit(2)
}
