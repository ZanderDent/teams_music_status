import SwiftUI
import TeamsMusicStatusCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab().tabItem { Label("General", systemImage: "gearshape") }
            StatusFormatTab().tabItem { Label("Status", systemImage: "text.quote") }
            PermissionsTab().tabItem { Label("Permissions", systemImage: "lock.shield") }
            DiagnosticsTab().tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 520, height: 430)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Music source", selection: $settings.sourceKind) {
                    ForEach(PresenceSourceKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                Text(settings.sourceKind.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Timing") {
                Picker("Restore my status after", selection: $settings.pauseGrace) {
                    ForEach(AppSettings.pauseGraceChoices, id: \.seconds) { choice in
                        Text(choice.label).tag(choice.seconds)
                    }
                }
                Text("How long playback can stay paused before your previous Teams status "
                     + "comes back. Resuming sooner changes nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("Wait before updating") {
                    HStack {
                        Slider(value: $settings.debounce, in: 0...30, step: 1)
                        Text("\(Int(settings.debounce))s").monospacedDigit().frame(width: 34)
                    }
                }
                Text("Skipping through tracks makes one Teams update instead of many.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Teams") {
                Picker("Clear my status after", selection: $settings.clearAfter) {
                    ForEach(TeamsSelectors.clearAfterOptions.filter { $0 != "Custom" }, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                Toggle("Show my status when people message me", isOn: $settings.showWhenMessaged)
                Text("Teams does not report this checkbox's state to macOS, so it can only be "
                     + "set when Teams exposes it. If it stays unchecked, tick it once in "
                     + "Teams by hand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if environment.loginItem.isSupported {
                Section {
                    Toggle("Launch at login", isOn: Binding(
                        get: { environment.loginItem.isEnabled },
                        set: { environment.loginItem.setEnabled($0) }
                    ))
                    if let error = environment.loginItem.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Status format

struct StatusFormatTab: View {
    @EnvironmentObject private var settings: AppSettings

    private var preview: String {
        settings.template.render(StatusTemplate.previewPresence)
    }

    var body: some View {
        Form {
            Section("Template") {
                TextField("Template", text: $settings.template.raw, axis: .vertical)
                    .lineLimit(2...3)
                    .font(.body.monospaced())

                HStack {
                    Button("Reset to default") {
                        settings.template = StatusTemplate()
                    }
                    .controlSize(.small)
                    Spacer()
                }
            }

            Section("Placeholders") {
                ForEach(StatusTemplate.Placeholder.allCases, id: \.self) { placeholder in
                    LabeledContent(placeholder.rawValue) {
                        Text(placeholder.explanation)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }

            Section("Preview") {
                Text(preview.isEmpty ? "—" : preview)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

                Text("\(preview.count) of \(TeamsSelectors.statusCharacterLimit) characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.template.raw.unicodeScalars.contains(where: { $0.value > 0xFFFF }) {
                    Label("Emoji above the Basic Multilingual Plane cannot be typed into Teams "
                          + "in the background, so they are replaced (🎵 becomes ♪).",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Permissions

struct PermissionsTab: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @State private var hasAccessibility = TeamsAccessibility.hasAccessibilityPermission
    @State private var recheckTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Accessibility") {
                LabeledContent("Status") {
                    Label(hasAccessibility ? "Granted" : "Not granted",
                          systemImage: hasAccessibility ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(hasAccessibility ? .green : .red)
                }
                Text("Required. Teams Music Status uses the macOS Accessibility API to open "
                     + "your Teams profile menu and type your status, exactly as you would. "
                     + "It never reads your messages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !hasAccessibility {
                    Button("Open Accessibility settings…") {
                        TeamsAccessibility.requestAccessibilityPermission()
                        TeamsAccessibility.openAccessibilitySettings()
                    }
                }
            }

            Section("Automation") {
                Text("Only needed for the Local Spotify source, which reads the Spotify app "
                     + "on this Mac. macOS will ask the first time it is used. The Spotify "
                     + "Web API source does not need it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Currently required") {
                    Text(settings.sourceKind == .spotifyLocal ? "Yes" : "No")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Spotify account") {
                LabeledContent("Connection") {
                    Text(environment.spotifyAuth.isAuthorized ? "Connected" : "Not connected")
                        .foregroundStyle(.secondary)
                }
                Text("Sign-in uses OAuth with PKCE. No client secret is used, and your tokens "
                     + "are stored in the macOS Keychain — never in files or logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if environment.spotifyAuth.isAuthorized {
                    Button("Disconnect Spotify") { environment.disconnectSpotify() }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(recheckTimer) { _ in
            // Live recheck: the user grants permission in System Settings, not in our app.
            hasAccessibility = TeamsAccessibility.hasAccessibilityPermission
        }
    }
}

// MARK: - Diagnostics

struct DiagnosticsTab: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var coordinator: PresenceCoordinator
    @State private var isRunning = false

    var body: some View {
        Form {
            Section("Microsoft Teams") {
                LabeledContent("Installed version") {
                    Text(TeamsProcesses.installedVersion() ?? "not installed")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Last verified version") {
                    Text(TeamsVersionTracker().lastVerifiedVersion ?? "never")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Accessibility") {
                    Text(String(describing: environment.accessibility.health()))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Selector self-test") {
                HStack {
                    Button(isRunning ? "Running…" : "Run self-test") {
                        isRunning = true
                        Task {
                            await coordinator.runSelfTestIfNeeded(force: true)
                            isRunning = false
                        }
                    }
                    .disabled(isRunning)
                    if isRunning { ProgressView().controlSize(.small) }
                }
                Text("Opens and closes your Teams profile menu to check that every control "
                     + "the automation needs is still where it expects. Nothing is saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let report = coordinator.lastSelfTest {
                    ScrollView {
                        Text(report.summary)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 130)
                }
            }
        }
        .formStyle(.grouped)
    }
}
