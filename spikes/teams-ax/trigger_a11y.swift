// trigger_a11y.swift — Experiment B8: force WebView2/Chromium inside Teams to publish
// its renderer accessibility tree.
//
// Symptom: after a Teams restart the window subtree stops at a bare AXGroup ~7 levels
// down; the AXWebArea (and everything the automation needs) is absent. Node count sits
// at ~249 (essentially just the native menu bar + window chrome) indefinitely.
//
// Chromium only builds the renderer a11y tree once it believes an assistive technology
// is present. This tries each known detection channel and reports which one flips it.
//
// Build: swiftc -O trigger_a11y.swift -o trigger_a11y && ./trigger_a11y
import AppKit
import ApplicationServices

func nodeCount(_ el: AXUIElement, _ maxDepth: Int = 30) -> Int {
    var n = 0
    func walk(_ e: AXUIElement, _ d: Int) {
        n += 1
        guard d < maxDepth else { return }
        var c: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &c) == .success,
           let kids = c as? [AXUIElement] { for k in kids { walk(k, d + 1) } }
    }
    walk(el, 0)
    return n
}
func hasWebArea(_ el: AXUIElement) -> Bool {
    var found = false
    func walk(_ e: AXUIElement, _ d: Int) {
        if found || d > 30 { return }
        var r: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &r) == .success,
           (r as? String) == "AXWebArea" { found = true; return }
        var c: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &c) == .success,
           let kids = c as? [AXUIElement] { for k in kids { walk(k, d + 1) } }
    }
    walk(el, 0)
    return found
}

guard let teams = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.teams2").first else {
    print("Teams not running"); exit(1)
}
let pid = teams.processIdentifier
let axApp = AXUIElementCreateApplication(pid)

func report(_ label: String) {
    print("  [\(label)] nodes=\(nodeCount(axApp)) webArea=\(hasWebArea(axApp) ? "YES ✅" : "no")")
}
print("Teams pid=\(pid)")
report("baseline")

// ── T5: register an AXObserver ────────────────────────────────────────
// Subscribing to AX notifications is the strongest "an AT is watching" signal an app
// can see; VoiceOver and every screen reader does exactly this.
print("\n--- T5: AXObserver registration on the Teams process ---")
var observer: AXObserver?
let cb: AXObserverCallback = { _, _, _, _ in }
let mk = AXObserverCreate(pid, cb, &observer)
print("  AXObserverCreate -> \(mk.rawValue)")
if let obs = observer {
    for note in [kAXFocusedUIElementChangedNotification,
                 kAXValueChangedNotification,
                 kAXWindowCreatedNotification,
                 kAXApplicationActivatedNotification,
                 kAXMainWindowChangedNotification,
                 kAXCreatedNotification,
                 kAXLayoutChangedNotification] {
        let r = AXObserverAddNotification(obs, axApp, note as CFString, nil)
        print("  add \(note) -> \(r.rawValue)")
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
    for i in 1...10 {
        CFRunLoopRunInMode(.defaultMode, 1.0, false)
        if hasWebArea(axApp) { print("  >>> web area appeared after \(i)s of observing"); break }
    }
}
report("after AXObserver")

// ── T6: touch the WebView helper processes' AX trees ──────────────────
print("\n--- T6: AX reads against the WebView helper processes ---")
func webViewPids() -> [pid_t] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "pgrep -f 'Microsoft Teams WebView'"]
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return out.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
}
for hp in webViewPids() {
    let hax = AXUIElementCreateApplication(hp)
    let n = nodeCount(hax, 10)
    let web = hasWebArea(hax)
    if n > 1 || web { print("  helper pid \(hp): nodes=\(n) webArea=\(web)") }
    var names: CFArray?
    AXUIElementCopyAttributeNames(hax, &names)
    _ = AXUIElementSetAttributeValue(hax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
}
Thread.sleep(forTimeInterval: 2.0)
report("after helper touch")

// ── T7: focused-element polling ───────────────────────────────────────
// Chromium's auto-enable heuristic keys off sustained AX querying, then builds the
// tree asynchronously; poll rather than sampling once.
print("\n--- T7: sustained AXFocusedUIElement polling (30s) ---")
for i in 1...30 {
    var f: CFTypeRef?
    AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &f)
    var w: CFTypeRef?
    AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &w)
    if hasWebArea(axApp) { print("  >>> web area appeared at t=\(i)s"); break }
    if i % 10 == 0 { report("t=\(i)s") }
    Thread.sleep(forTimeInterval: 1.0)
}
report("final")
