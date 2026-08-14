import AppKit
import SwiftUI
import TeamsMusicStatusCore

/// First-run flow.
///
/// Three principles, learned from watching this go wrong:
///
/// 1. **Every step verifies itself.** A tick means the thing actually works — the source
///    step turns green only after a real read of what is playing, not after a checkbox.
/// 2. **Nothing is deferred to "go find it later".** Spotify is connected here, sync is
///    switched on here. Previously the user finished onboarding and then had to discover
///    a menu-bar icon they had never seen to do anything at all.
/// 3. **The app is invisible by design**, so the last screen says where it lives.
struct OnboardingView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var model: OnboardingModel
    @State private var launchAtLogin = false

    var onFinish: () -> Void

    init(environment: AppEnvironment, onFinish: @escaping () -> Void) {
        _model = StateObject(wrappedValue: OnboardingModel(environment: environment))
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    accessibilityStep
                    sourceStep
                    teamsStep
                }
                .padding(24)
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 700)
        .onAppear {
            model.startPolling()
            launchAtLogin = model.launchAtLoginEnabled
        }
        .onDisappear { model.stopPolling() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "music.note")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("Teams Music Status").font(.title2.weight(.semibold))
                Text("Shows what you're listening to as your Microsoft Teams status.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
    }

    // MARK: Step 1 — Accessibility

    private var accessibilityStep: some View {
        step(number: 1, title: "Allow Accessibility access", done: model.hasAccessibility) {
            if model.hasAccessibility {
                Text("Granted. Teams Music Status can update your status.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Teams has no API for the custom status message, so this app updates it "
                         + "the way you would: it opens your profile menu and types.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Label("It never reads your messages, and it never takes your keyboard — "
                          + "updates happen in the background while you keep working.",
                          systemImage: "hand.raised")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Allow Accessibility Access…") { model.requestAccessibility() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Allow Accessibility access")

                    Text(.init("Switch on **TeamsMusicStatus** in the list that opens. "
                               + "This window updates by itself once you do."))
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Step 2 — Music source

    private var sourceStep: some View {
        step(number: 2, title: "Connect your music", done: model.sourceCheck.isReady) {
            VStack(alignment: .leading, spacing: 12) {
                if let problem = model.configurationProblem,
                   model.settings.sourceKind == .spotifyWebAPI {
                    calloutRow(icon: "exclamationmark.triangle", tint: .orange, text: problem)
                }

                Picker("", selection: Binding(
                    get: { model.settings.sourceKind },
                    set: { model.settings.sourceKind = $0; model.sourceChanged() }
                )) {
                    ForEach(PresenceSourceKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Text(model.settings.sourceKind.summary)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                sourceActions
            }
        }
    }

    @ViewBuilder
    private var sourceActions: some View {
        HStack(spacing: 10) {
            if model.needsSpotifySignIn {
                Button(model.isConnecting ? "Waiting for Spotify…" : "Sign in to Spotify…") {
                    model.connectSpotify()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isConnecting || model.configurationProblem != nil)
                .accessibilityLabel("Sign in to Spotify")
            } else {
                // `.bordered` and `.borderedProminent` are different types, so they cannot
                // be selected with a ternary inside `.buttonStyle`.
                let check = Button(checkButtonTitle) { Task { await model.verifySource() } }
                    .disabled(model.sourceCheck == .checking)
                    .accessibilityLabel(checkButtonTitle)
                if model.sourceCheck.isReady {
                    check.buttonStyle(.bordered)
                } else {
                    check.buttonStyle(.borderedProminent)
                }
            }
            if model.isConnecting || model.sourceCheck == .checking {
                ProgressView().controlSize(.small)
            }
        }

        if let error = model.connectError {
            calloutRow(icon: "xmark.circle", tint: .red, text: error)
        }

        switch model.sourceCheck {
        case .ready(let nowPlaying):
            if let nowPlaying {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your Teams status will read").font(.caption).foregroundStyle(.tertiary)
                    Text(nowPlaying)
                        .font(.body.monospaced()).textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            } else {
                Text("Connected. Nothing is playing right now — start a track and your status "
                     + "will follow.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let message):
            calloutRow(icon: "exclamationmark.triangle", tint: .orange, text: message)
        case .notChecked, .checking:
            EmptyView()
        }
    }

    private var checkButtonTitle: String {
        if model.sourceCheck.isReady { return "Check again" }
        return model.settings.sourceKind == .spotifyLocal ? "Check Spotify Access" : "Check Connection"
    }

    // MARK: Step 3 — Teams

    private var teamsStep: some View {
        step(number: 3, title: "Microsoft Teams", done: model.teamsRunning) {
            if model.teamsRunning {
                Text("Teams is running. Your status will update automatically — you can leave "
                     + "it in the background or minimised.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Teams isn't running, so there's nothing to update yet. Start it and "
                         + "this will tick itself.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Microsoft Teams") { model.launchTeams() }
                        .accessibilityLabel("Open Microsoft Teams")
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "menubar.arrow.up.rectangle").foregroundStyle(.secondary)
                // Concatenate Text values rather than interpolating an Image into a
                // String: `"\(Image(...))"` stringifies the SwiftUI value and literally
                // renders "Image(provider: SwiftUI.ImageProviderBox<...>)" on screen.
                (Text("Teams Music Status lives in your menu bar — look for the ")
                 + Text(Image(systemName: "music.note"))
                 + Text(" icon. It has no Dock icon."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.launchAtLoginSupported {
                Toggle("Start Teams Music Status when I log in", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .onChange(of: launchAtLogin) { _, newValue in model.setLaunchAtLogin(newValue) }
                    .accessibilityLabel("Start Teams Music Status when I log in")
            }

            HStack {
                Button("Set up later") {
                    model.finish(enableSync: false)
                    onFinish()
                }
                .accessibilityLabel("Set up later")

                Spacer()

                Button(model.canFinish ? "Start Syncing" : "Finish") {
                    model.finish(enableSync: model.canFinish)
                    onFinish()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canFinish)
                .accessibilityLabel(model.canFinish ? "Start syncing" : "Finish setup")
            }
        }
        .padding(24)
    }

    // MARK: Building blocks

    @ViewBuilder
    private func step<Content: View>(number: Int, title: String, done: Bool,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.secondary.opacity(0.2))
                    .frame(width: 24, height: 24)
                if done {
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.caption.bold()).foregroundStyle(.secondary)
                }
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number), \(title), \(done ? "complete" : "not complete")")
    }

    private func calloutRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Hosts `OnboardingView` in a normal window.
///
/// The app is `LSUIElement`, so it has no Dock icon and its windows open behind whatever
/// the user is doing unless the app is explicitly activated. On a first run that would
/// mean the setup window is simply never seen.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    func show(environment: AppEnvironment, onClose: (() -> Void)? = nil) {
        self.onClose = onClose

        if let window {
            bringToFront(window)
            return
        }

        let controller = NSHostingController(
            rootView: OnboardingView(environment: environment,
                                     onFinish: { [weak self] in self?.close() })
                .environmentObject(environment)
                .environmentObject(environment.settings)
                .environmentObject(environment.coordinator)
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "Set Up Teams Music Status"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        centerOnMainScreen(window)
        self.window = window
        bringToFront(window)
    }

    /// Put the setup window on the screen with the menu bar.
    ///
    /// `NSWindow.center()` uses whichever screen macOS considers main at that instant,
    /// which on a multi-display Mac is not necessarily the one the user is looking at —
    /// measured here opening at y = -1415, i.e. on a display above the primary. For a
    /// window whose whole job is to be noticed on first launch, that is a failure.
    private func centerOnMainScreen(_ window: NSWindow) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main ?? NSScreen.screens.first else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            // Slightly above centre reads better than dead centre for a dialog.
            y: visible.midY - size.height / 2 + visible.height * 0.06
        ))
    }

    private func bringToFront(_ window: NSWindow) {
        // Briefly become a regular app so the setup window can take focus like any other,
        // then drop back to accessory so no Dock icon lingers once it is dismissed.
        //
        // The activation MUST happen on a later run-loop turn. Activating in the same
        // turn as the policy change silently does nothing: measured on a clean first run,
        // the setup window opened *behind* Microsoft Teams, so a new user would launch
        // the app and see nothing at all.
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            // Belt and braces: if something else grabs focus in the same moment, a second
            // pass a beat later still puts the window in front of it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        onClose?()
    }
}
