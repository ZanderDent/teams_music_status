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
    /// Lets the menu reopen setup. Without a route back, anyone whose setup was dismissed
    /// or skipped had no way to reach it again short of deleting their preferences.
    static weak var shared: AppDelegate?
    private let onboarding = OnboardingWindowController()

    /// Reopen the setup window on demand.
    func showOnboarding() {
        guard let environment = Self.sharedEnvironment else { return }
        onboarding.show(environment: environment)
    }

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

        Self.shared = self

        // Show the first-run explainer when onboarding has not been completed, or when
        // the Accessibility grant has since been revoked and nothing can work without it.
        //
        // `sharedEnvironment` is published by the menu-bar label's `onAppear`, which is a
        // different lifecycle to this one. A single fixed delay that finds it still nil
        // used to return silently and never try again, so a launch that lost that race
        // produced a menu-bar icon and nothing else — permanently, with no way to reach
        // setup. Retry briefly rather than betting the entire first-run experience on one
        // arbitrary deadline.
        waitForEnvironmentThenShowOnboardingIfNeeded(attemptsRemaining: 20)
    }

    private func waitForEnvironmentThenShowOnboardingIfNeeded(attemptsRemaining: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            guard let environment = Self.sharedEnvironment else {
                if attemptsRemaining > 0 {
                    self.waitForEnvironmentThenShowOnboardingIfNeeded(
                        attemptsRemaining: attemptsRemaining - 1)
                } else {
                    Log.app.error("setup could not be shown: the app environment never became available")
                }
                return
            }
            // Logged at every launch, and deliberately not behind the debug flag. "Did
            // setup open, and if not why not?" is the first question for any report that
            // the app does nothing, and it was previously unanswerable from outside.
            // Names the branch only — no account, status or track information.
            // Drive the startup checks from launch rather than from a window appearing.
            // The source repair and the selector self-test both live behind this, and a
            // first-run user may never open the menu-bar panel that used to be the only
            // thing that triggered it.
            Task { await environment.performStartupChecks() }

            let decision = OnboardingPolicy.decide(
                hasCompletedOnboarding: environment.settings.hasCompletedOnboarding,
                hasAccessibility: TeamsAccessibility.hasAccessibilityPermission)
            Log.app.info("setup check: \(decision.logDescription, privacy: .public)")
            if decision.shouldShow {
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
