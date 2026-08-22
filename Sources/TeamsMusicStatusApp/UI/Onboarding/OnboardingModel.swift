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

    /// An action the user can take to get themselves unstuck, when the failure is one
    /// macOS will not re-prompt for on its own.
    enum RecoveryAction: Equatable {
        case openAutomationSettings
    }

    @Published private(set) var hasAccessibility = false
    @Published private(set) var teamsRunning = false
    @Published private(set) var sourceCheck: SourceCheck = .notChecked
    /// Non-nil when `sourceCheck` is a failure the user can act on. Kept separate from
    /// `SourceCheck.failed` so the view can stay a plain string render.
    @Published private(set) var recoveryAction: RecoveryAction?
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

    /// Whether the Spotify desktop app is even installed. Checked without Apple Events,
    /// so it cannot launch Spotify or trigger a permission prompt.
    var isSpotifyInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyLocalSource.bundleIdentifier) != nil
    }

    var isSpotifyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: SpotifyLocalSource.bundleIdentifier).isEmpty
    }

    /// Prove the source works by reading from it.
    ///
    /// Onboarding is Local-only by design (see `OnboardingView.sourceStep`), so this
    /// *makes* the local source the active one rather than assuming it already is. That
    /// assumption was the v1.0.0 first-run blocker. `AppSettings.resolveSourceKind` then
    /// keyed on `hasCompletedOnboarding`, so every profile that had ever finished setup —
    /// i.e. every machine upgrading from v1.0.0 — resolved to `.spotifyWebAPI` and had it
    /// written down permanently. Step 2 silently verified the **Web API** source: no Apple
    /// Event was ever sent, macOS had nothing to prompt for, and the Web API's
    /// `.notAuthorized` description — "Spotify is not connected." — was shown to a user who
    /// had never been asked for anything. That resolution now keys on real credentials
    /// instead; pinning here closes the same hole from the onboarding side.
    ///
    /// The order below matters. Consent is classified first so a never-asked user can be
    /// prompted deliberately, and the read is still attempted in every case: inspecting
    /// TCC alone would leave a fresh user waiting for a permission that nothing had asked
    /// for.
    func verifySource() async {
        sourceCheck = .checking
        recoveryAction = nil

        // Make sure the profile has a source that can actually reach Spotify, using the
        // repair that owns this decision rather than writing `sourceKind` here.
        //
        // Two reasons it must be the repair and not a direct write. A direct assignment
        // fires `sourceKind`'s `didSet`, which records `sourceChosenExplicitly` — falsely
        // marking a choice the user never made, and permanently disabling the repair for
        // that profile. And the repair alone honours an explicit Web API choice, so
        // someone who picked it in Settings and has not connected yet is left alone
        // instead of being dragged onto the local source every time setup opens.
        //
        // Done here as well as in `AppEnvironment.performStartupChecks()`, which now runs
        // at launch rather than from the menu-bar panel appearing. Repeating it is free —
        // the repair is idempotent and no-ops when the source is already correct — and it
        // keeps this step correct on its own rather than dependent on launch ordering.
        //
        // The Keychain read is on a detached task: a synchronous SecItemCopyMatching on
        // the main thread is the securityd hang `SpotifyAuth.init` documents.
        let hasCredentials = await Task.detached(priority: .utility) {
            SpotifyAuth.hasStoredCredentials()
        }.value
        settings.repairSourceKind(hasWebAPICredentials: hasCredentials)

        guard isSpotifyInstalled else {
            sourceCheck = .failed("Spotify isn't installed on this Mac. Install the Spotify "
                                + "desktop app from spotify.com, then check again.")
            return
        }
        guard isSpotifyRunning else {
            sourceCheck = .failed("Open Spotify, then try again.")
            return
        }

        // Ask macOS for consent *before* reading when it has never been asked. A menu-bar
        // app cannot rely on NSAppleScript to raise the dialog — when it cannot, it just
        // returns -1743, which is indistinguishable from a refusal.
        if await automationPermission(promptIfNeeded: false) == .notDetermined {
            _ = await automationPermission(promptIfNeeded: true)
        }

        do {
            let presence = try await environment.activeSource.fetch()
            let rendered = presence.map {
                settings.template.render($0, maskProfanity: settings.maskProfanity)
            }
            if presence == nil {
                sourceCheck = .failed("Spotify is open but nothing is playing. Start a track, "
                                    + "then check again.")
                return
            }
            sourceCheck = .ready(nowPlaying: presence?.isPlaying == true ? rendered : nil)
        } catch PresenceSourceError.automationPermissionDenied {
            // -1743 means "not permitted" and nothing more. Only this second, non-prompting
            // classification separates a user who pressed Don't Allow from one macOS never
            // got round to asking.
            switch await automationPermission(promptIfNeeded: false) {
            case .denied:
                sourceCheck = .failed("Spotify access is blocked. Enable Teams Music Status "
                                    + "under System Settings ▸ Privacy & Security ▸ Automation.")
                recoveryAction = .openAutomationSettings
            case .notDetermined:
                sourceCheck = .failed("Spotify access is required. Choose Check Spotify and "
                                    + "allow access when macOS asks.")
            case .granted:
                // The read was refused but consent is in place: a race with Spotify
                // quitting, or a transient refusal. Sending this user to System Settings
                // would have them hunt for a switch that is already on.
                sourceCheck = .failed("Couldn't read Spotify yet. Try again.")
            case .targetNotRunning:
                sourceCheck = .failed("Open Spotify, then try again.")
            case .unknown(let status):
                // -1743 did happen, so treat an unrecognised follow-up as blocked rather
                // than as noise — the recovery route is harmless if it turns out not to be.
                Log.spotify.error("automation consent unclassified: \(status, privacy: .public)")
                sourceCheck = .failed("Spotify access is blocked. Enable Teams Music Status "
                                    + "under System Settings ▸ Privacy & Security ▸ Automation.")
                recoveryAction = .openAutomationSettings
            }
        } catch PresenceSourceError.appNotRunning {
            sourceCheck = .failed("Open Spotify, then try again.")
        } catch PresenceSourceError.timedOut {
            sourceCheck = .failed("Couldn't read Spotify yet. Try again.")
        } catch PresenceSourceError.appleEventFailure(let code, _) {
            Log.spotify.error("onboarding source check failed, Apple Event \(code, privacy: .public)")
            sourceCheck = .failed("Couldn't read Spotify yet. Try again.")
        } catch let error as PresenceSourceError {
            sourceCheck = .failed(error.localizedDescription)
        } catch {
            sourceCheck = .failed(error.localizedDescription)
        }
    }

    /// Off the main thread: with `promptIfNeeded` this blocks until the user answers.
    private func automationPermission(promptIfNeeded: Bool) async -> AutomationPermission {
        await Task.detached(priority: .userInitiated) {
            SpotifyAutomation.permission(promptIfNeeded: promptIfNeeded)
        }.value
    }

    /// The way out of a denied state, which macOS will not re-prompt for.
    func performRecovery() {
        switch recoveryAction {
        case .openAutomationSettings: SpotifyAutomation.openAutomationSettings()
        case nil: break
        }
    }

    func sourceChanged() {
        sourceCheck = .notChecked
        connectError = nil
        recoveryAction = nil
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
        // "Install once and forget it" is not achievable without this: an app that does
        // not return after a reboot has to be noticed and restarted by hand. Only applies
        // when the user never expressed a preference — an explicit choice is never
        // overridden.
        environment.enableLaunchAtLoginByDefault()
        stopPolling()
    }

    /// User-initiated only. Records the choice so the default above can never undo it.
    func setLaunchAtLogin(_ enabled: Bool) {
        environment.setLaunchAtLogin(enabled, userInitiated: true)
    }

    /// What the checkbox should show before it is touched: a fresh install previews the
    /// default it is about to get, an existing install shows what it actually has.
    var launchAtLoginIntent: Bool {
        settings.launchAtLoginChosenExplicitly ? environment.loginItem.isEnabled : true
    }

    var launchAtLoginEnabled: Bool { environment.loginItem.isEnabled }
    var launchAtLoginSupported: Bool { environment.loginItem.isSupported }
}
