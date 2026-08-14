// unlock_a11y.swift — Experiment B6: after a Teams restart the WebView2 renderer
// exposes only ~20 AX nodes (window chrome, no web content). Find the trigger that
// makes Chromium build its renderer accessibility tree.
//
// Chromium gates the renderer a11y tree on assistive-technology detection. Candidate
// triggers, cheapest first:
//   T1  AXManualAccessibility on the main app element        (Chrome's documented opt-in)
//   T2  AXManualAccessibility on the WebView helper process  (WebView2 hosts the renderer
//                                                             in a separate pid)
//   T3  AXEnhancedUserInterface on either                    (AppKit-wide legacy opt-in)
//   T4  reading AXChildren of the web area repeatedly        (Chromium auto-enable heuristic)
//
// Build: swiftc -O unlock_a11y.swift -o unlock_a11y && ./unlock_a11y
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
func errName(_ e: AXError) -> String {
    switch e {
    case .success: return "success"
    case .attributeUnsupported: return "attributeUnsupported"
    case .notImplemented: return "notImplemented"
    case .cannotComplete: return "cannotComplete"
    case .illegalArgument: return "illegalArgument"
    default: return "raw(\(e.rawValue))"
    }
}

guard let teams = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.teams2").first else {
    print("Teams not running"); exit(1)
}
let mainPid = teams.processIdentifier
let axMain = AXUIElementCreateApplication(mainPid)
print("main Teams pid=\(mainPid)  baseline nodes=\(nodeCount(axMain))")

// WebView2 runs the renderer in "Microsoft Teams WebView" helper processes.
func webViewPids() -> [pid_t] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "pgrep -f 'Microsoft Teams WebView' | head -20"]
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return out.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
}

func trySet(_ label: String, _ el: AXUIElement, _ attr: String) {
    let r = AXUIElementSetAttributeValue(el, attr as CFString, kCFBooleanTrue)
    print("  \(label) \(attr) -> \(errName(r))")
}

print("\n--- T1/T3: attributes on the main app element ---")
trySet("main", axMain, "AXManualAccessibility")
trySet("main", axMain, "AXEnhancedUserInterface")

print("\n--- T2/T3: attributes on each WebView helper pid ---")
for pid in webViewPids() {
    let ax = AXUIElementCreateApplication(pid)
    print(" pid \(pid) (nodes=\(nodeCount(ax, 4)))")
    trySet("  ", ax, "AXManualAccessibility")
    trySet("  ", ax, "AXEnhancedUserInterface")
}

print("\n--- T4: repeated deep reads, polling for the tree to appear ---")
for i in 1...12 {
    let n = nodeCount(axMain)
    print("  poll \(i): nodes=\(n)")
    if n > 100 { print("  >>> TREE MATERIALISED after \(i) polls"); break }
    Thread.sleep(forTimeInterval: 2.0)
}
print("\nfinal nodes=\(nodeCount(axMain))")
