import Foundation
import ServiceManagement

/// Launch-at-login via `SMAppService` (macOS 13+), which needs no helper bundle and no
/// deprecated `SMLoginItemSetEnabled` shim.
///
/// Only meaningful for a real, signed `.app` — when the executable is run straight from
/// the build directory the registration is rejected, so the UI hides the control instead
/// of offering something that cannot work.
@MainActor
public final class LoginItemService: ObservableObject {

    @Published public private(set) var isEnabled: Bool = false
    @Published public private(set) var lastError: String?

    private var service: SMAppService { .mainApp }

    public init() { refresh() }

    /// Whether launch-at-login can work in this build. False when running the raw
    /// SwiftPM binary rather than an installed .app bundle.
    public var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    public func refresh() {
        isEnabled = service.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) {
        guard isSupported else {
            lastError = "Launch at login is only available when running the installed app."
            return
        }
        do {
            if enabled {
                if service.status == .enabled { try service.unregister() }
                try service.register()
            } else {
                try service.unregister()
            }
            lastError = nil
            Log.app.info("launch at login \(enabled ? "enabled" : "disabled", privacy: .public)")
        } catch {
            // The common case is the user having denied it in System Settings ▸ Login Items.
            lastError = error.localizedDescription
            Log.app.error("launch at login change failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    /// Deep link to where the user can override this decision.
    public static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
