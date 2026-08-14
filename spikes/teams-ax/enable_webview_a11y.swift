// enable_webview_a11y.swift — the minimal action that makes Teams' WebView2 renderer
// publish its accessibility tree. This is the single most important finding of the
// Teams spike: without it, a freshly started Teams exposes NO web content to the
// Accessibility API and the whole automation is impossible.
//
// Teams 2.x hosts its UI in Microsoft Edge WebView2 (Chromium). Chromium keeps its
// renderer accessibility tree switched off until it detects an assistive technology.
// The main app process ignores both AXManualAccessibility and AXEnhancedUserInterface
// (attributeUnsupported / notImplemented) — the switch lives on the separate
// "Microsoft Teams WebView" helper process.
//
// Build: swiftc -O enable_webview_a11y.swift -o enable_webview_a11y
// Usage: ./enable_webview_a11y [--mode manual|read|both] [--wait SECONDS]
//   manual  only set AXManualAccessibility on each helper pid
//   read    only deep-read each helper pid's AX tree
//   both    (default) do both
import AppKit
import ApplicationServices

let args = CommandLine.arguments
func flag(_ n: String, _ d: String) -> String {
    guard let i = args.firstIndex(of: n), i + 1 < args.count else { return d }
    return args[i + 1]
}
let mode = flag("--mode", "both")
let wait = Double(flag("--wait", "10")) ?? 10

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

guard let teams = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.teams2").first else {
    print("Teams not running"); exit(1)
}
let axApp = AXUIElementCreateApplication(teams.processIdentifier)
print("mode=\(mode)  before: nodes=\(nodeCount(axApp)) webArea=\(hasWebArea(axApp))")

/// Every helper process WebView2 spawns for the renderer. The tree-bearing one is not
/// identifiable up front, so touch them all — it costs a handful of IPC round-trips.
func webViewPids() -> [pid_t] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "pgrep -f 'Microsoft Teams WebView'"]
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return out.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
}

let pids = webViewPids()
print("helper pids: \(pids)")
for hp in pids {
    let hax = AXUIElementCreateApplication(hp)
    if mode == "manual" || mode == "both" {
        let r = AXUIElementSetAttributeValue(hax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        print("  pid \(hp) set AXManualAccessibility -> \(r.rawValue)")
    }
    if mode == "read" || mode == "both" {
        let n = nodeCount(hax, 10)
        var names: CFArray?
        AXUIElementCopyAttributeNames(hax, &names)
        print("  pid \(hp) deep-read -> \(n) nodes")
    }
}

let deadline = Date().addingTimeInterval(wait)
while Date() < deadline {
    if hasWebArea(axApp) {
        print("RESULT: webArea present, nodes=\(nodeCount(axApp)) ✅")
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.5)
}
print("RESULT: no webArea after \(wait)s, nodes=\(nodeCount(axApp)) ❌")
exit(1)
