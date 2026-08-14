import AppKit
import SwiftUI
import TeamsMusicStatusCore

/// Menu-bar-only application.
///
/// `LSUIElement` in Info.plist keeps it out of the Dock and the app switcher; the whole
/// interface is the `MenuBarExtra` plus a Settings window.
@main
struct TeamsMusicStatusApp: App {

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
                .onAppear { AppDelegate.sharedEnvironment = environment }
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by the app scene so the delegate can present onboarding against the same
    /// environment the UI is using.
    static weak var sharedEnvironment: AppEnvironment?
    private let onboarding = OnboardingWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces: Info.plist already sets LSUIElement, but running the binary
        // directly (development) would otherwise bounce a Dock icon.
        NSApp.setActivationPolicy(.accessory)
        // Recorded at every launch: "does the app hold Accessibility?" is the first
        // question for any support issue, and the answer is not otherwise visible.
        Log.app.info("""
            Teams Music Status started — accessibility granted: \
            \(TeamsAccessibility.hasAccessibilityPermission, privacy: .public), \
            Teams running: \(TeamsProcesses.isRunning, privacy: .public)
            """)

        // Show the first-run explainer when onboarding has not been completed, or when
        // the Accessibility grant has since been revoked and nothing can work without it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let environment = Self.sharedEnvironment else { return }
            let needsOnboarding = !environment.settings.hasCompletedOnboarding
                || !TeamsAccessibility.hasAccessibilityPermission
            if needsOnboarding {
                self.onboarding.show(environment: environment)
            }
        }
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
            .accessibilityLabel("Teams Music Status — \(state.title)")
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
