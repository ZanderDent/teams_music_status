import AppKit
import Darwin
import Foundation

/// Locating Teams and its WebView2 helper processes.
///
/// Teams 2.x is not Electron: the UI runs in Microsoft Edge WebView2, and the renderer
/// lives in separate `Microsoft Teams WebView` helper processes. Those helpers are the
/// surface Chromium watches for assistive-technology contact, so the enabler needs their
/// pids — see `TeamsAccessibility`.
public enum TeamsProcesses {
    public static let bundleIdentifier = "com.microsoft.teams2"

    /// Substring identifying the WebView2 helper processes in their executable path.
    private static let webViewHelperMarker = "Microsoft Teams WebView"

    public static func runningApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    public static var isRunning: Bool { runningApp() != nil }

    public static func pid() -> pid_t? { runningApp()?.processIdentifier }

    /// Installed Teams version, read from the bundle rather than from any running process
    /// so it is available even when Teams is not running.
    public static func installedVersion() -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
              let bundle = Bundle(url: url) else { return nil }
        return bundle.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    public static func applicationURL() -> URL? {
        runningApp()?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// Every `Microsoft Teams WebView` helper pid, found by walking the process table.
    ///
    /// Uses libproc directly rather than shelling out to `pgrep`: a menu-bar utility that
    /// spawns a subprocess on a timer is both slower and noisier than it needs to be.
    public static func webViewHelperPIDs() -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity + 64)
        let byteCount = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count))
        guard byteCount > 0 else { return [] }
        let count = Int(byteCount) / MemoryLayout<pid_t>.size

        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is not exported to Swift.
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var result: [pid_t] = []
        for index in 0..<count {
            let candidate = pids[index]
            guard candidate > 0 else { continue }
            let length = proc_pidpath(candidate, &pathBuffer, UInt32(pathBuffer.count))
            guard length > 0 else { continue }
            let path = String(cString: pathBuffer)
            if path.contains(webViewHelperMarker) {
                result.append(candidate)
            }
        }
        return result
    }
}
