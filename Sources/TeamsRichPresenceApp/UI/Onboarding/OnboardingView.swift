import AppKit
import SwiftUI
import TeamsRichPresenceCore

/// First-run explainer.
///
/// Accessibility is a powerful permission and users are right to hesitate before granting
/// it. Rather than firing the system prompt out of nowhere, say plainly what the app does
/// with it and — just as importantly — what it does not.
struct OnboardingView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: AppSettings

    @State private var hasAccessibility = TeamsAccessibility.hasAccessibilityPermission
    private let recheck = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Teams Rich Presence")
                    .font(.title2.weight(.semibold))
                Text("Shows what you're listening to as your Microsoft Teams status.")
                    .foregroundStyle(.secondary)
            }

            Divider()

            step(number: 1,
                 title: "Allow Accessibility access",
                 done: hasAccessibility) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Teams has no API for the custom status message, so this app updates "
                         + "it the same way you would: it opens your profile menu and types. "
                         + "macOS calls that Accessibility access.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Label("It never reads your Teams messages, and it does not take over your "
                          + "keyboard — updates happen in the background while you keep working.",
                          systemImage: "hand.raised")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !hasAccessibility {
                        Button("Open Accessibility settings…") {
                            TeamsAccessibility.requestAccessibilityPermission()
                            TeamsAccessibility.openAccessibilitySettings()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            step(number: 2,
                 title: "Connect a music source",
                 done: environment.isSpotifyConnected) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Source", selection: $settings.sourceKind) {
                        ForEach(PresenceSourceKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    Text(settings.sourceKind.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Text(hasAccessibility
                     ? "You're ready. Open the menu-bar icon to turn syncing on."
                     : "Accessibility access is required before syncing can start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    settings.hasCompletedOnboarding = true
                    onFinish()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520, height: 460)
        .onReceive(recheck) { _ in
            hasAccessibility = TeamsAccessibility.hasAccessibilityPermission
        }
    }

    @ViewBuilder
    private func step<Content: View>(number: Int, title: String, done: Bool,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.secondary.opacity(0.25))
                    .frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.caption.bold())
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content()
            }
        }
    }
}

/// Hosts `OnboardingView` in a normal window. The app is `LSUIElement`, so the window has
/// to be activated explicitly or it opens behind everything.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    func show(environment: AppEnvironment) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(
            rootView: OnboardingView(onFinish: { [weak self] in self?.close() })
                .environmentObject(environment)
                .environmentObject(environment.settings)
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "Welcome to Teams Rich Presence"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }
}
