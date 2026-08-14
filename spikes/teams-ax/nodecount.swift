// nodecount.swift — helper for restart_probe.sh.
//   ./nodecount                  print the node count of the Teams AX tree
//   ./nodecount --touch-webview  additionally issue AX reads against every
//                                "Microsoft Teams WebView" helper pid (Chromium's
//                                assistive-technology detection surface)
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

guard let teams = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.teams2").first else {
    print("0"); exit(1)
}

if CommandLine.arguments.contains("--touch-webview") {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "pgrep -f 'Microsoft Teams WebView' | head -20"]
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    for pid in out.split(separator: "\n").compactMap({ pid_t($0.trimmingCharacters(in: .whitespaces)) }) {
        let ax = AXUIElementCreateApplication(pid)
        _ = nodeCount(ax, 6)
        var names: CFArray?
        AXUIElementCopyAttributeNames(ax, &names)
    }
    exit(0)
}

print(nodeCount(AXUIElementCreateApplication(teams.processIdentifier)))
