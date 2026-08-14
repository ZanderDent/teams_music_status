// dump.swift — Experiment B1: walk and print the Teams AXUIElement tree.
//
// Build: swiftc -O dump.swift -o dump
// Usage: ./dump [maxDepth] [--enhance]
//   --enhance  sets AXEnhancedUserInterface=true on the app first (Chromium/WebView2
//              only materialises its full a11y tree once an AT client announces itself).
import AppKit
import ApplicationServices

let args = CommandLine.arguments
let maxDepth = Int(args.dropFirst().first(where: { Int($0) != nil }) ?? "") ?? 12
let enhance = args.contains("--enhance")

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}
func str(_ el: AXUIElement, _ name: String) -> String? {
    guard let v = attr(el, name) else { return nil }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}
func actions(_ el: AXUIElement) -> [String] {
    var a: CFArray?
    guard AXUIElementCopyActionNames(el, &a) == .success else { return [] }
    return (a as? [String]) ?? []
}

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.teams2").first else {
    print("Teams not running"); exit(1)
}
let axApp = AXUIElementCreateApplication(app.processIdentifier)

if enhance {
    let r = AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    print("// set AXEnhancedUserInterface -> \(r.rawValue)")
    // give Chromium a moment to build the tree
    Thread.sleep(forTimeInterval: 1.5)
}

var nodeCount = 0
func walk(_ el: AXUIElement, depth: Int, path: String) {
    nodeCount += 1
    let pad = String(repeating: "  ", count: depth)
    let role = str(el, kAXRoleAttribute as String) ?? "?"
    var line = "\(pad)\(role)"
    if let sub = str(el, kAXSubroleAttribute as String) { line += " [\(sub)]" }
    for k in ["AXIdentifier", kAXTitleAttribute as String, kAXDescriptionAttribute as String,
              kAXValueAttribute as String, kAXHelpAttribute as String,
              kAXRoleDescriptionAttribute as String, kAXPlaceholderValueAttribute as String] {
        if var s = str(el, k), !s.isEmpty {
            if s.count > 90 { s = String(s.prefix(90)) + "…" }
            line += " \(k.replacingOccurrences(of: "AX", with: ""))=\"\(s)\""
        }
    }
    let acts = actions(el).filter { $0 != "AXShowMenu" || true }
    if !acts.isEmpty { line += " actions=\(acts)" }
    line += "  @\(path)"
    print(line)

    guard depth < maxDepth else { print("\(pad)  …(depth cap)"); return }
    guard let kids = attr(el, kAXChildrenAttribute as String) as? [AXUIElement] else { return }
    for (i, k) in kids.enumerated() { walk(k, depth: depth + 1, path: "\(path)/\(i)") }
}

print("=== AXApplication tree (pid \(app.processIdentifier), maxDepth=\(maxDepth), enhance=\(enhance)) ===")
walk(axApp, depth: 0, path: "")
print("=== \(nodeCount) nodes ===")
