#if os(Windows)
import Foundation

// The Windows front door for logging. Deliberately mirrors the macOS `Log` in
// `Log.swift` — same categories, same call sites, same secrets policy — so shared code
// logs identically on both platforms.
//
// There is no unified logging on Windows, so this writes to a rotating file under
// %LOCALAPPDATA% and mirrors to stderr when debug logging is on.

/// How a value may appear in a log line.
///
/// Reproduces the part of `os_log`'s privacy model that matters here: **interpolated
/// values are private by default** and are redacted unless the call site explicitly marks
/// them public. That default is what makes it hard to leak something by accident, and it
/// is the reason this shim exists rather than plain string interpolation.
public enum LogPrivacy: Sendable {
    case `public`
    case `private`
}

/// A log message whose interpolations carry a privacy decision.
///
/// `Log.app.info("launch at login \(enabled ? "on" : "off", privacy: .public)")` therefore
/// compiles and behaves the same way it does on macOS.
public struct LogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral, Sendable {
    public let rendered: String

    public init(stringLiteral value: String) { self.rendered = value }
    public init(stringInterpolation: StringInterpolation) { self.rendered = stringInterpolation.output }

    public struct StringInterpolation: StringInterpolationProtocol {
        var output = ""

        public init(literalCapacity: Int, interpolationCount: Int) {
            output.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        public mutating func appendLiteral(_ literal: String) { output += literal }

        public mutating func appendInterpolation(_ value: String, privacy: LogPrivacy = .private) {
            output += (privacy == .public) ? value : "<private>"
        }

        public mutating func appendInterpolation(_ value: some CustomStringConvertible,
                                                 privacy: LogPrivacy = .private) {
            output += (privacy == .public) ? value.description : "<private>"
        }

        /// Non-string values with no explicit privacy. Numbers and enum cases are not
        /// secrets, and forcing `privacy:` on every count and duration would make the
        /// annotation noise rather than signal.
        public mutating func appendInterpolation(_ value: Any) {
            output += String(describing: value)
        }
    }
}

/// One named category, matching the shape of `os.Logger` at the call sites this project uses.
public struct Logger: Sendable {
    let subsystem: String
    let category: String

    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
    }

    public func debug(_ message: LogMessage) { emit("DEBUG", message) }
    public func info(_ message: LogMessage) { emit("INFO", message) }
    public func notice(_ message: LogMessage) { emit("NOTICE", message) }
    public func warning(_ message: LogMessage) { emit("WARN", message) }
    public func error(_ message: LogMessage) { emit("ERROR", message) }
    public func fault(_ message: LogMessage) { emit("FAULT", message) }

    private func emit(_ level: String, _ message: LogMessage) {
        LogSink.shared.write(level: level, category: category, message: message.rendered)
    }
}

/// Where log lines actually go.
///
/// One file per day under `%LOCALAPPDATA%\TeamsMusicStatus\Logs`, pruned to the last two
/// weeks. A desktop utility that writes a status message all day will otherwise grow a log
/// nobody ever deletes.
final class LogSink: @unchecked Sendable {
    static let shared = LogSink()

    private let queue = DispatchQueue(label: "com.zanderdent.TeamsMusicStatus.log")
    private let directory: URL
    private let formatter: DateFormatter
    private let dayFormatter: DateFormatter

    private init() {
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("TeamsMusicStatus").appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"

        queue.async { [directory, dayFormatter] in
            Self.prune(directory: directory, dayFormatter: dayFormatter)
        }
    }

    /// The file the current day's lines go to.
    var currentFile: URL {
        directory.appendingPathComponent("tms-\(dayFormatter.string(from: Date())).log")
    }

    func write(level: String, category: String, message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(category): \(message)\n"

        if Log.isDebugEnabled {
            FileHandle.standardError.write(Data(line.utf8))
        }

        // Synchronous, deliberately. An async write is lost if the process exits before the
        // queue drains — which means the one log line that matters most, the last one
        // before an unexplained exit, is precisely the one that never reaches disk. This
        // logs a handful of lines a minute, so serialising them costs nothing worth having.
        queue.sync { [currentFile] in
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: currentFile) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: currentFile)
            }
        }
    }

    private static func prune(directory: URL, dayFormatter: DateFormatter, keepDays: Int = 14) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86_400)
        for file in files where file.lastPathComponent.hasPrefix("tms-") {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }
}

/// Categories, matching `Log.swift` on macOS one for one.
///
/// Secrets policy, identical to the macOS side and enforced by `Redact`: access tokens,
/// refresh tokens, authorization codes, PKCE verifiers and client secrets are NEVER passed
/// to a logger, not even at debug level, and not even marked private. The only permitted
/// representation of a secret is its length, via `Redact.secret(_:)`.
public enum Log {
    public static let subsystem = "com.zanderdent.TeamsMusicStatus"

    public static let teams = Logger(subsystem: subsystem, category: "teams")
    public static let accessibility = Logger(subsystem: subsystem, category: "accessibility")
    public static let spotify = Logger(subsystem: subsystem, category: "spotify")
    public static let oauth = Logger(subsystem: subsystem, category: "oauth")
    public static let coordinator = Logger(subsystem: subsystem, category: "coordinator")
    public static let keychain = Logger(subsystem: subsystem, category: "credentials")
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let selfTest = Logger(subsystem: subsystem, category: "selftest")

    /// Verbose diagnostics. Off unless the user opts in with `TMS_DEBUG=1`.
    public static var isDebugEnabled: Bool = {
        ProcessInfo.processInfo.environment["TMS_DEBUG"] == "1"
    }()

    public static func debug(_ logger: Logger, _ message: @autoclosure () -> String) {
        guard isDebugEnabled else { return }
        logger.info(LogMessage(stringLiteral: "[debug] " + message()))
    }

    public static func mirrorToStandardError(_ message: String) {
        guard isDebugEnabled else { return }
        FileHandle.standardError.write(Data("[tms] \(message)\n".utf8))
    }

    /// Where the user can find today's log, for a bug report.
    public static var logFileURL: URL { LogSink.shared.currentFile }
}

/// Helpers that make it hard to log something you shouldn't. Identical to macOS.
public enum Redact {
    /// The ONLY permitted representation of a secret in any output.
    public static func secret(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "<none>" }
        return "<\(value.count) chars>"
    }

    /// Status message text is not secret, but it is personal and it lands in logs a user
    /// may paste into a bug report. Keep the shape, drop most of the content.
    public static func status(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "<empty>" }
        let scalarCount = value.unicodeScalars.count
        let head = String(value.prefix(12))
        return "\"\(head)\(scalarCount > 12 ? "…" : "")\" (\(scalarCount) scalars)"
    }
}
#endif
