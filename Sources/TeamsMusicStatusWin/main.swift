import CTeamsWin
import Foundation
import TeamsMusicStatusCore
import TeamsMusicStatusWindows

// Teams Music Status for Windows.
//
// The counterpart of the macOS menu-bar app: an icon in the notification area, no window
// unless you ask for one. The Win32 plumbing lives in CTeamsWin; this file is the shell
// that wires settings, the sync loop and the menu together.
//
// C callbacks cannot capture, so the application is a singleton reached through `app`.
// That is the whole reason for the global — nothing else here depends on it.

/// Menu command ids. Also the ids posted from the sync thread onto the UI thread.
enum Command: Int32 {
    case primary = 1          // double-click on the icon
    case toggleSync = 10
    case openSettings = 11
    case openLogFolder = 12
    case resumeAfterOverride = 13
    case about = 15
    case quit = 99
    /// Posted from the sync thread when status changes, so the tray is only ever touched
    /// from the UI thread.
    case refreshUI = 200
}

final class TrayApp {
    let settings = WindowsSettings()
    let coordinator: WindowsPresenceCoordinator
    private var lastStatus = WindowsPresenceCoordinator.Status()

    init() {
        coordinator = WindowsPresenceCoordinator(settings: settings, source: WindowsMediaSource())
        coordinator.onStatusChange = { [weak self] status in
            self?.lastStatus = status
            // Shell_NotifyIcon from a non-UI thread is a source of intermittent,
            // unreproducible failures, so the update is marshalled rather than applied.
            _ = tw_tray_post_to_ui(Command.refreshUI.rawValue)
        }
    }

    // MARK: - Lifecycle

    func run() -> Int32 {
        guard tw_single_instance_acquire("TeamsMusicStatus.SingleInstance".wideBuffer) == 1 else {
            tw_message_box("Teams Music Status".wideBuffer,
                           "Teams Music Status is already running. Look for the ♪ icon in the notification area.".wideBuffer,
                           0)
            return 0
        }

        Log.app.info("starting")

        if !settings.hasCompletedOnboarding {
            runOnboarding()
        }

        guard tw_tray_init("Teams Music Status".wideBuffer, handleCommand, nil) == TW_OK else {
            tw_message_box("Teams Music Status".wideBuffer,
                           "The notification-area icon could not be created.".wideBuffer, 1)
            return 1
        }
        tw_tray_set_menu_builder(buildMenu, nil)

        if settings.syncEnabled { coordinator.start() }
        refreshUI()

        let result = tw_tray_run()
        // Leaving the status behind would be rude: it says the user is listening to
        // something when the app is no longer running to update it.
        coordinator.stop(restore: true)
        Log.app.info("stopped")
        return result
    }

    // MARK: - Onboarding

    /// First run. Shows what was detected, because a user whose Teams is not running is
    /// better told now than left with a status that silently never updates.
    private func runOnboarding() {
        var form = TWOnboardingForm()

        // `availability()` opens the accessibility tree first, which matters here: before
        // anything has opened it the health model reports `treeUnavailable`, and that is
        // not the same as Teams being absent. Reporting "Teams is not running" to someone
        // whose Teams is plainly open is the kind of wrong first impression that makes
        // people give up on first launch.
        _ = TeamsWindowsTarget().availability()
        let health = TeamsWindowsHealth.current()
        form.teamsReady = (health != .notRunning && health != .noWindow) ? 1 : 0
        withUnsafeMutablePointer(to: &form.teamsVersion) {
            $0.withMemoryRebound(to: UInt16.self, capacity: Int(TW_ID_MAX)) { buffer in
                copyIn(TeamsWindowsHealth.teamsVersion() ?? "", into: buffer, capacity: Int(TW_ID_MAX))
            }
        }

        let playing = try? WindowsMediaSource().read()
        form.playerReady = playing != nil ? 1 : 0
        let playerLine = playing.map { "Spotify — \($0.trackName) by \($0.joinedArtists)" }
            ?? "Nothing is playing yet. Start Spotify and press play."
        withUnsafeMutablePointer(to: &form.playerState) {
            $0.withMemoryRebound(to: UInt16.self, capacity: Int(TW_NAME_MAX)) { buffer in
                copyIn(playerLine, into: buffer, capacity: Int(TW_NAME_MAX))
            }
        }

        form.launchAtLoginSupported = WindowsLoginItem.isSupported ? 1 : 0
        form.launchAtLogin = 0

        let finished = tw_onboarding_dialog(&form)
        guard finished == 1 else {
            // Closed without finishing. Onboarding is deliberately *not* marked complete,
            // so it is offered again next launch rather than leaving the app in a state
            // the user never agreed to. "Set up later" meaning "never" was a real bug on
            // macOS; this is the same trap.
            Log.app.info("onboarding dismissed without finishing")
            return
        }

        settings.hasCompletedOnboarding = true
        settings.syncEnabled = form.enableSync == 1
        if form.launchAtLoginSupported == 1 {
            applyLaunchAtLogin(form.launchAtLogin == 1)
        }
        Log.app.info("onboarding finished, sync \(settings.syncEnabled ? "enabled" : "left off", privacy: .public)")
    }

    // MARK: - Menu

    func rebuildMenu() {
        let status = coordinator.currentStatus
        tw_tray_menu_begin()

        // A disabled first line, showing what the app currently believes. This is the
        // whole diagnostic surface for a user who never opens a terminal.
        let headline: String
        if status.selectorsBroken != nil {
            // Deliberately blunt. This state needs an app update to clear, so telling the
            // user syncing is merely "having trouble" would leave them waiting for a
            // recovery that is not coming.
            headline = "Paused — this Teams version changed its interface"
        } else if status.manualOverride {
            headline = "Paused — you changed your status in Teams"
        } else if let error = status.lastError {
            headline = "Problem: \(error)"
        } else if let published = status.lastPublished {
            headline = published
        } else if let playing = status.nowPlaying {
            headline = "Playing: \(playing)"
        } else {
            headline = "Nothing is playing"
        }
        tw_tray_menu_add(0, headline.wideBuffer, 0, 0)

        if status.isRunning, !status.manualOverride, status.lastError == nil {
            tw_tray_menu_add(0, "Teams: \(status.targetAvailability)".wideBuffer, 0, 0)
        }

        tw_tray_menu_add_separator()
        tw_tray_menu_add(Command.toggleSync.rawValue, "Sync my status".wideBuffer,
                         settings.syncEnabled ? 1 : 0, 1)

        if status.manualOverride {
            tw_tray_menu_add(Command.resumeAfterOverride.rawValue,
                             "Resume syncing (replaces your status)".wideBuffer, 0, 1)
        }

        tw_tray_menu_add_separator()
        tw_tray_menu_add(Command.openSettings.rawValue, "Settings…".wideBuffer, 0, 1)
        tw_tray_menu_add(Command.openLogFolder.rawValue, "Open log folder".wideBuffer, 0, 1)
        tw_tray_menu_add(Command.about.rawValue, "About Teams Music Status".wideBuffer, 0, 1)
        tw_tray_menu_add_separator()
        tw_tray_menu_add(Command.quit.rawValue, "Quit".wideBuffer, 0, 1)
    }

    // MARK: - Commands

    func handle(_ command: Command) {
        switch command {
        case .primary, .toggleSync:
            setSyncEnabled(!settings.syncEnabled)

        case .resumeAfterOverride:
            coordinator.resumeAfterManualOverride()
            refreshUI()

        case .openSettings:
            showSettings()

        case .openLogFolder:
            _ = tw_shell_open(Log.logFileURL.deletingLastPathComponent().path.wideBuffer)

        case .about:
            tw_message_box("Teams Music Status".wideBuffer, aboutText().wideBuffer, 0)

        case .quit:
            tw_tray_quit()

        case .refreshUI:
            refreshUI()
        }
    }

    private func setSyncEnabled(_ enabled: Bool) {
        settings.syncEnabled = enabled
        if enabled {
            coordinator.start()
        } else {
            // Restores the user's original status, but only if Teams still shows what this
            // app wrote — text they typed themselves is theirs and is left alone.
            coordinator.stop(restore: true)
        }
        refreshUI()
    }

    private func showSettings() {
        var form = TWSettingsForm()
        withUnsafeMutablePointer(to: &form.templateText) {
            $0.withMemoryRebound(to: UInt16.self, capacity: Int(TW_NAME_MAX)) { buffer in
                copyIn(settings.template.raw, into: buffer, capacity: Int(TW_NAME_MAX))
            }
        }
        form.maskProfanity = settings.maskProfanity ? 1 : 0
        form.launchAtLogin = WindowsLoginItem.isEnabled ? 1 : 0
        form.launchAtLoginSupported = WindowsLoginItem.isSupported ? 1 : 0
        form.pauseGraceSeconds = Int32(settings.pauseGrace.isFinite ? settings.pauseGrace : 0)
        form.pollSeconds = Int32(settings.pollInterval)

        guard tw_settings_dialog(&form, providePreview, nil) == 1 else { return }

        settings.template = StatusTemplate(readString(&form.templateText, Int(TW_NAME_MAX)))
        settings.maskProfanity = form.maskProfanity == 1
        // Zero is the "Never" choice; the engine expects an effectively infinite grace.
        settings.pauseGrace = form.pauseGraceSeconds == 0
            ? .greatestFiniteMagnitude
            : TimeInterval(form.pauseGraceSeconds)
        if form.launchAtLoginSupported == 1 {
            applyLaunchAtLogin(form.launchAtLogin == 1)
        }
        Log.app.info("settings saved")
        refreshUI()
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        switch WindowsLoginItem.setEnabled(enabled) {
        case .success:
            settings.launchAtLogin = enabled
        case .failure(let error):
            tw_message_box("Teams Music Status".wideBuffer,
                           error.localizedDescription.wideBuffer, 1)
        }
    }

    /// What the settings window shows under the template field.
    func preview(for templateText: String) -> String {
        let template = StatusTemplate(templateText)
        // The track that is really playing, so the preview is about the user's own music
        // rather than a canned example. Falls back to the shared sample when nothing is on.
        let presence = (try? WindowsMediaSource().read()) ?? StatusTemplate.previewPresence
        return template.render(presence, maskProfanity: settings.maskProfanity)
    }

    private func aboutText() -> String {
        """
        Shows what you are listening to as your Microsoft Teams status message.

        Teams:    \(TeamsWindowsHealth.teamsVersion() ?? "not running")
        Settings: \(settings.location.path)
        Log:      \(Log.logFileURL.path)

        zanderdent.com/teams-music-status
        """
    }

    // MARK: - Presentation

    func refreshUI() {
        let status = coordinator.currentStatus

        let iconState: Int32
        if status.manualOverride || status.lastError != nil {
            iconState = TW_ICON_PROBLEM
        } else if status.isRunning {
            iconState = TW_ICON_ACTIVE
        } else {
            iconState = TW_ICON_IDLE
        }
        _ = tw_tray_set_icon(iconState)

        var tooltip = "Teams Music Status"
        if !settings.syncEnabled {
            tooltip += " — off"
        } else if status.manualOverride {
            tooltip += " — paused, you changed your status"
        } else if let published = status.lastPublished {
            tooltip += "\n\(published)"
        } else if let playing = status.nowPlaying {
            tooltip += "\n\(playing)"
        }
        // The tooltip field is fixed at 128 characters; anything longer is dropped
        // entirely rather than truncated by the shell.
        _ = tw_tray_set_tooltip(String(tooltip.prefix(120)).wideBuffer)
    }
}

// MARK: - C interop

/// UTF-16, NUL-terminated, for the wide entry points in CTeamsWin.
extension String {
    var wideBuffer: [UInt16] { Array(utf16) + [0] }
}

private func copyIn(_ value: String, into buffer: UnsafeMutablePointer<UInt16>, capacity: Int) {
    let units = Array(value.utf16.prefix(capacity - 1))
    for (index, unit) in units.enumerated() { buffer[index] = unit }
    buffer[units.count] = 0
}

private func readString<T>(_ buffer: inout T, _ capacity: Int) -> String {
    withUnsafeBytes(of: &buffer) { raw in
        let units = raw.bindMemory(to: UInt16.self)
        let end = units.firstIndex(of: 0) ?? units.count
        return String(decoding: units[..<end], as: UTF16.self)
    }
}

// C function pointers cannot capture, so these reach the application through the global.
private let handleCommand: TWCommandHandler = { commandId, _ in
    guard let command = Command(rawValue: commandId) else { return }
    app?.handle(command)
}

private let buildMenu: TWCommandHandler = { _, _ in
    app?.rebuildMenu()
}

private let providePreview: TWPreviewProvider = { templateText, out, capacity, _ in
    guard let templateText, let out, let app else { return }

    var units: [UInt16] = []
    var cursor = templateText
    while cursor.pointee != 0 {
        units.append(cursor.pointee)
        cursor += 1
    }
    let text = String(decoding: units, as: UTF16.self)

    let rendered = Array(app.preview(for: text).utf16.prefix(Int(capacity) - 1))
    for (index, unit) in rendered.enumerated() { out[index] = unit }
    out[rendered.count] = 0
}

// MARK: - Entry point

private let app: TrayApp? = TrayApp()
exit(app?.run() ?? 1)
