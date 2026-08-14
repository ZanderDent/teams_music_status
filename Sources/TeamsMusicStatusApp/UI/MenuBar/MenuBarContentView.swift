import SwiftUI
import TeamsMusicStatusCore

/// The menu-bar panel: current state, what Teams is showing, and the controls people
/// actually reach for. Anything more configurable lives in Settings.
struct MenuBarContentView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var coordinator: PresenceCoordinator
    @EnvironmentObject private var settings: AppSettings

    @State private var isConnecting = false
    @State private var connectionError: String?

    private var isOverridden: Bool {
        if case .manualOverrideDetected = coordinator.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 8)

            if let problem = environment.configurationProblem {
                calloutRow(icon: "gearshape.badge.xmark", tint: .orange, text: problem)
                Divider().padding(.vertical, 8)
            }

            statusSection

            if case .manualOverrideDetected = coordinator.state {
                Button("Resume automatic updates") { coordinator.resumeAfterManualOverride() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 6)
                    .accessibilityLabel("Resume automatic status updates")
            }

            if !coordinator.lastWarnings.isEmpty {
                ForEach(coordinator.lastWarnings, id: \.self) { warning in
                    calloutRow(icon: "info.circle", tint: .secondary, text: warning)
                }
            }

            Divider().padding(.vertical, 8)
            controls
            Divider().padding(.vertical, 8)
            footer
        }
        .padding(14)
        .frame(width: 320)
        .task { await environment.performStartupChecks() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Teams Music Status")
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(severityColor)
                        .frame(width: 7, height: 7)
                    Text(coordinator.state.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var severityColor: Color {
        switch coordinator.state.severity {
        case .active: return .green
        case .idle: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    // MARK: Status

    @ViewBuilder
    private var statusSection: some View {
        if let detail = coordinator.state.detail {
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let rendered = coordinator.renderedStatus, !rendered.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                // During a manual override this is what we *would* publish, not what
                // Teams is actually showing — saying "Showing in Teams" there would be
                // a plain lie, since the user's own status is on screen.
                Text(isOverridden ? "Would show in Teams" : "Showing in Teams")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(rendered)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            .padding(.top, 6)
        } else if let presence = coordinator.currentPresence, !presence.isPlaying {
            Text("Paused — \(presence.trackName)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 4)
        }

        if coordinator.state == .teamsAccessibilityPermissionMissing {
            Button("Open Accessibility settings…") {
                TeamsAccessibility.requestAccessibilityPermission()
                TeamsAccessibility.openAccessibilitySettings()
            }
            .controlSize(.small)
            .padding(.top, 6)
            .accessibilityLabel("Open Accessibility settings")
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Sync Spotify to Teams", isOn: $coordinator.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(environment.configurationProblem != nil && settings.sourceKind == .spotifyWebAPI)

            Picker("Source", selection: $settings.sourceKind) {
                ForEach(PresenceSourceKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)

            if settings.sourceKind == .spotifyWebAPI {
                spotifyConnectionRow
            }
        }
    }

    @ViewBuilder
    private var spotifyConnectionRow: some View {
        HStack(spacing: 8) {
            if environment.isSpotifyConnected {
                Button("Disconnect Spotify") { environment.disconnectSpotify() }
                    .controlSize(.small)
                    .accessibilityLabel("Disconnect Spotify")
            } else {
                Button(isConnecting ? "Waiting for Spotify…" : "Connect Spotify…") {
                    connect()
                }
                .controlSize(.small)
                .disabled(isConnecting || environment.configurationProblem != nil)
                .accessibilityLabel(isConnecting ? "Waiting for Spotify" : "Connect Spotify")
            }
            if isConnecting { ProgressView().controlSize(.small) }
        }
        if let connectionError {
            Text(connectionError)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connect() {
        isConnecting = true
        connectionError = nil
        Task {
            do { try await environment.connectSpotify() }
            catch { connectionError = error.localizedDescription }
            isConnecting = false
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if environment.loginItem.isSupported {
                Toggle("Launch at login", isOn: Binding(
                    get: { environment.loginItem.isEnabled },
                    set: { environment.loginItem.setEnabled($0) }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .accessibilityLabel("Launch at login")
            }

            HStack {
                SettingsLink { Text("Settings…") }
                    .controlSize(.small)
                    .accessibilityLabel("Open Settings")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
                    .accessibilityLabel("Quit Teams Music Status")
            }
        }
    }

    private func calloutRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}
