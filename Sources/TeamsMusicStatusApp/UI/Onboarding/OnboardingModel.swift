import AppKit
import Foundation
import SwiftUI
import TeamsMusicStatusCore

/// Live state behind the first-run flow.
///
/// Every step verifies itself by doing the real thing rather than by asking the user to
/// confirm they did it: the accessibility tick reflects `AXIsProcessTrusted`, the source
/// tick reflects an actual successful read of what is playing, and the Teams tick
/// reflects the app really being reachable. That way "all green" means the integration
/// will work, not that four boxes were ticked.
@MainActor
final class OnboardingModel: ObservableObject {

    enum SourceCheck: Equatable {
        case notChecked
        case checking
        case ready(nowPlaying: String?)
        case failed(String)

        var isReady: Bool { if case .ready = self { return true }; return false }
    }

    @Published private(set) var hasAccessibility = false
    @Published private(set) var teamsRunning = false
    @Published private(set) var sourceCheck: SourceCheck = .notChecked
    @Published var isConnecting = false
    @Published var connectError: String?

    private let environment: AppEnvironment
    private var timer: Timer?

    init(environment: AppEnvironment) {
        self.environment = environment
        refreshCheapState()
    }

    deinit { timer?.invalidate() }

    var settings: AppSettings { environment.settings }
    var isSpotifyConnected: Bool { environment.isSpotifyConnected }
    var configurationProblem: String? { environment.configurationProblem }

    /// Only the Web API source needs a sign-in; the local one needs macOS Automation
    /// consent instead, which is requested by actually trying to read.
    var needsSpotifySignIn: Bool {
        settings.sourceKind == .spotifyWebAPI && !environment.isSpotifyConnected
    }

    var canFinish: Bool { hasAccessibility && sourceCheck.isReady }

    // MARK: Polling

    /// Permissions are granted in System Settings, not in this app, so the only way to
    /// know is to keep looking.
    func startPolling() {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCheapState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refreshCheapState()
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func refreshCheapState() {
        let granted = TeamsAccessibility.hasAccessibilityPermission
        if granted != hasAccessibility { hasAccessibility = granted }
        let running = TeamsProcesses.isRunning
        if running != teamsRunning { teamsRunning = running }
    }

    // MARK: Step 1 — Accessibility

    /// Fires the system prompt *and* opens the pane. The prompt is what adds the app to
    /// the list in the first place; opening the pane saves the user a hunt through
    /// System Settings afterwards.
    func requestAccessibility() {
        TeamsAccessibility.requestAccessibilityPermission()
        TeamsAccessibility.openAccessibilitySettings()
    }

    // MARK: Step 2 — Music source

    func connectSpotify() {
        isConnecting = true
        connectError = nil
        Task {
            do {
                try await environment.connectSpotify()
                await verifySource()
            } catch {
                connectError = error.localizedDescription
            }
            isConnecting = false
        }
    }

    /// Prove the source works by reading from it.
    ///
    /// For the local source this is also what triggers the macOS Automation prompt —
    /// at the moment the user asked for it, rather than silently in a background poll
    /// where the reason for the prompt would be a mystery.
    func verifySource() async {
        sourceCheck = .checking
        do {
            let presence = try await environment.activeSource.fetch()
            let rendered = presence.map { settings.template.render($0) }
            sourceCheck = .ready(nowPlaying: presence?.isPlaying == true ? rendered : nil)
        } catch let error as PresenceSourceError {
            sourceCheck = .failed(error.localizedDescription)
        } catch {
            sourceCheck = .failed(error.localizedDescription)
        }
    }

    func sourceChanged() {
        sourceCheck = .notChecked
        connectError = nil
    }

    // MARK: Step 3 — Teams

    func launchTeams() {
        guard let url = TeamsProcesses.applicationURL() else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }

    // MARK: Finish

    /// Turn the integration on and remember that onboarding is done.
    func finish(enableSync: Bool) {
        settings.hasCompletedOnboarding = true
        if enableSync { environment.coordinator.isEnabled = true }
        stopPolling()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        environment.loginItem.setEnabled(enabled)
    }

    var launchAtLoginEnabled: Bool { environment.loginItem.isEnabled }
    var launchAtLoginSupported: Bool { environment.loginItem.isSupported }
}
