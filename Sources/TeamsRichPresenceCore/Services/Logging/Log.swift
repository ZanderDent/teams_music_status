import Foundation
import os

/// Unified-logging front door for the whole app.
///
/// Secrets policy, enforced by convention and by `Redact`: access tokens, refresh
/// tokens, authorization codes, PKCE verifiers and client secrets are NEVER passed to
/// a logger, not even at debug level, and not even as `.private`. The only permitted
/// representation of a secret is its length, via `Redact.secret(_:)`.
public enum Log {
    public static let subsystem = "com.zanderdent.TeamsRichPresence"

    public static let teams = Logger(subsystem: subsystem, category: "teams")
    public static let accessibility = Logger(subsystem: subsystem, category: "accessibility")
    public static let spotify = Logger(subsystem: subsystem, category: "spotify")
    public static let oauth = Logger(subsystem: subsystem, category: "oauth")
    public static let coordinator = Logger(subsystem: subsystem, category: "coordinator")
    public static let keychain = Logger(subsystem: subsystem, category: "keychain")
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let selfTest = Logger(subsystem: subsystem, category: "selftest")

    /// Verbose diagnostics for development. Off unless the user opts in.
    /// `defaults write com.zanderdent.TeamsRichPresence debugLogging -bool YES`
    /// or run with `TRP_DEBUG=1`.
    public static var isDebugEnabled: Bool = {
        if ProcessInfo.processInfo.environment["TRP_DEBUG"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: "debugLogging")
    }()

    public static func debug(_ logger: Logger, _ message: @autoclosure () -> String) {
        guard isDebugEnabled else { return }
        let rendered = message()
        logger.debug("\(rendered, privacy: .public)")
    }
}

/// Helpers that make it hard to log something you shouldn't.
public enum Redact {
    /// The ONLY permitted representation of a secret in any output.
    public static func secret(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "<none>" }
        return "<\(value.count) chars>"
    }

    /// Status message text is not secret, but it is personal and it lands in logs that
    /// a user may paste into a bug report. Keep the shape, drop most of the content.
    public static func status(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "<empty>" }
        let scalarCount = value.unicodeScalars.count
        let head = String(value.prefix(12))
        return "\"\(head)\(scalarCount > 12 ? "…" : "")\" (\(scalarCount) scalars)"
    }
}
