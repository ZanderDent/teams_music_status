// probe.swift — Experiment B0: can this process use the Accessibility API at all?
// Build: swiftc -O probe.swift -o probe && ./probe
import AppKit
import ApplicationServices

let trusted = AXIsProcessTrusted()
print("AXIsProcessTrusted() = \(trusted)")

let teams = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.teams2")
print("Teams running instances: \(teams.count)")
guard let app = teams.first else { print("Teams not running"); exit(1) }
print("  pid=\(app.processIdentifier) active=\(app.isActive) hidden=\(app.isHidden)")

let ax = AXUIElementCreateApplication(app.processIdentifier)
var names: CFArray?
let err = AXUIElementCopyAttributeNames(ax, &names)
print("AXUIElementCopyAttributeNames -> \(err.rawValue) (0 = success, -25211 = APIDisabled, -25204 = cannotComplete)")
if err == .success, let n = names as? [String] {
    print("  app attributes: \(n)")
    var winsRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &winsRef) == .success,
       let wins = winsRef as? [AXUIElement] {
        print("  window count: \(wins.count)")
        for (i, w) in wins.enumerated() {
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
            print("    [\(i)] title=\(t as? String ?? "<none>")")
        }
    }
}
