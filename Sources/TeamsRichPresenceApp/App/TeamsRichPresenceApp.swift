import AppKit
import SwiftUI
import TeamsRichPresenceCore

/// Menu-bar-only application.
///
/// `LSUIElement` in Info.plist keeps it out of the Dock and the app switcher; the whole
/// interface is the `MenuBarExtra` plus a Settings window.
@main
struct TeamsRichPresenceApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(environment)
                .environmentObject(environment.coordinator)
                .environmentObject(environment.settings)
        } label: {
            MenuBarLabel(state: environment.coordinator.state)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(environment)
                .environmentObject(environment.coordinator)
                .environmentObject(environment.settings)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces: Info.plist already sets LSUIElement, but running the binary
        // directly (development) would otherwise bounce a Dock icon.
        NSApp.setActivationPolicy(.accessory)
        Log.app.info("Teams Rich Presence started")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

/// The menu-bar glyph. Uses SF Symbols so it renders correctly in light, dark and tinted
/// menu bars without shipping assets.
struct MenuBarLabel: View {
    let state: AppState

    var body: some View {
        Image(systemName: symbolName)
            .symbolRenderingMode(.hierarchical)
            .accessibilityLabel("Teams Rich Presence — \(state.title)")
    }

    private var symbolName: String {
        switch state.severity {
        case .active: return "music.note"
        case .idle: return "music.note.list"
        case .warning: return "exclamationmark.triangle"
        case .error: return "exclamationmark.circle"
        }
    }
}
