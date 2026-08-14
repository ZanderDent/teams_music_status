// enable_a11y.swift — Experiment B2: find the switch that makes WebView2/Chromium
// materialise its full accessibility tree inside Teams.
//
// Chromium gates its renderer a11y tree behind AT detection. On macOS the documented
// opt-in for embedders is the `AXManualAccessibility` attribute (Chrome), with
// `AXEnhancedUserInterface` being the older AppKit-wide equivalent.
//
// Build: swiftc -O enable_a11y.swift -o enable_a11y && ./enable_a11y
import AppKit
import ApplicationServices

func errName(_ e: AXError) -> String {
    switch e {
    case .success: return "success"
    case .failure: return "failure(-25200)"
    case .illegalArgument: return "illegalArgument(-25201)"
    case .invalidUIElement: return "invalidUIElement(-25202)"
    case .cannotComplete: return "cannotComplete(-25204)"
    case .attributeUnsupported: return "attributeUnsupported(-25205)"
    case .actionUnsupported: return "actionUnsupported(-25206)"
    case .notImplemented: return "notImplemented(-25208)"
    case .noValue: return "noValue(-25212)"
    default: return "raw(\(e.rawValue))"
    }
}

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.teams2").first else {
    print("Teams not running"); exit(1)
}
let axApp = AXUIElementCreateApplication(app.processIdentifier)

func webContentGroupDescendantCount() -> Int {
    var n = 0
    func walk(_ el: AXUIElement, _ d: Int) {
        n += 1
        guard d < 25 else { return }
        var c: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &c) == .success,
           let kids = c as? [AXUIElement] { for k in kids { walk(k, d + 1) } }
    }
    var w: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &w) == .success,
          let wins = w as? [AXUIElement], let first = wins.first else { return 0 }
    walk(first, 0)
    return n
}

print("baseline window subtree nodes: \(webContentGroupDescendantCount())")

for candidate in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
    let r = AXUIElementSetAttributeValue(axApp, candidate as CFString, kCFBooleanTrue)
    print("set \(candidate)=true -> \(errName(r))")
    if r == .success {
        for wait in [0.5, 1.0, 2.0] {
            Thread.sleep(forTimeInterval: wait)
            print("   after \(wait)s cumulative: \(webContentGroupDescendantCount()) nodes")
        }
    }
}
