// observer_trigger.swift — Experiment B9: isolate the AXObserver as the thing that
// makes Teams' WebView2 renderer publish its accessibility tree.
//
// Ruled out by B8 on a freshly restarted Teams (each tested alone, 15-20s window):
//   * AXManualAccessibility on the main app        -> attributeUnsupported
//   * AXEnhancedUserInterface on the main app      -> notImplemented
//   * AXManualAccessibility on the WebView helpers -> attributeUnsupported / cannotComplete
//   * deep AX reads of the WebView helper trees    -> no effect
//   * System Events UI-scripting poke              -> no effect
//   * simply waiting (7 minutes)                   -> no effect
//
// What remains is AXObserverCreate + AXObserverAddNotification with a live CFRunLoop
// source: the same registration a screen reader performs. Chromium treats it as
// assistive-technology detection and builds the renderer tree a few seconds later.
//
// Build: swiftc -O observer_trigger.swift -o observer_trigger
// Usage: ./observer_trigger [seconds]        default 60
import AppKit
import ApplicationServices

let budget = Double(CommandLine.arguments.dropFirst().first ?? "60") ?? 60

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
func nodeCount(_ el: AXUIElement) -> Int {
    var n = 0
    func walk(_ e: AXUIElement, _ d: Int) {
        n += 1
        guard d < 30 else { return }
        var c: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &c) == .success,
           let kids = c as? [AXUIElement] { for k in kids { walk(k, d + 1) } }
    }
    walk(el, 0)
    return n
}

guard let teams = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.teams2").first else {
    print("Teams not running"); exit(1)
}
let pid = teams.processIdentifier
let axApp = AXUIElementCreateApplication(pid)
print("pid=\(pid) before: nodes=\(nodeCount(axApp)) webArea=\(hasWebArea(axApp))")

var observer: AXObserver?
guard AXObserverCreate(pid, { _, _, _, _ in }, &observer) == .success, let obs = observer else {
    print("AXObserverCreate failed"); exit(2)
}
// Registering for notifications is the AT signal. The specific notifications matter
// less than the fact that a run-loop-backed observer exists on the process.
for note in [kAXFocusedUIElementChangedNotification,
             kAXValueChangedNotification,
             kAXWindowCreatedNotification,
             kAXMainWindowChangedNotification,
             kAXLayoutChangedNotification] {
    let r = AXObserverAddNotification(obs, axApp, note as CFString, nil)
    print("  add \(note) -> \(r.rawValue)")
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)

// With the observer live, touch the WebView helper processes. Neither half works
// alone (B8/B9): the observer establishes "an AT is present" and the helper contact
// is what makes the renderer actually hand over its tree.
if CommandLine.arguments.contains("--touch") {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "pgrep -f 'Microsoft Teams WebView'"]
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let hpids = out.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    print("  touching helper pids \(hpids) while the observer is live")
    for hp in hpids {
        let hax = AXUIElementCreateApplication(hp)
        var names: CFArray?
        AXUIElementCopyAttributeNames(hax, &names)
        _ = nodeCount(hax)
        _ = AXUIElementSetAttributeValue(hax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}

let start = Date()
while Date().timeIntervalSince(start) < budget {
    CFRunLoopRunInMode(.defaultMode, 1.0, false)
    let t = Int(Date().timeIntervalSince(start))
    if hasWebArea(axApp) {
        print("web area appeared at t=\(t)s, nodes=\(nodeCount(axApp)) ✅")
        exit(0)
    }
    if t % 10 == 0 { print("  t=\(t)s nodes=\(nodeCount(axApp))") }
}
print("no web area after \(Int(budget))s ❌")
exit(1)
