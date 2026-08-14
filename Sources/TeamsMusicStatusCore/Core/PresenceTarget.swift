import Foundation

/// Where presence is published. Teams is the only implementation today; a Windows Teams
/// target (UI Automation) would satisfy the same contract.
public protocol PresenceTarget: AnyObject {
    var id: String { get }
    var displayName: String { get }

    /// Whether the target can currently accept a write, and why not if it cannot.
    func availability() -> TargetAvailability

    /// Read the status message the target currently shows, or nil if it has none.
    /// Throws when the target cannot be read at all.
    func readCurrentStatus() throws -> String?

    /// Write `status`, then verify by reading it back. Throws if it did not take.
    func apply(status: String) throws

    /// Remove the status message entirely.
    func clearStatus() throws

    /// Prepare the target for use: repair accessibility, validate selectors.
    func prepare() throws
}

public enum TargetAvailability: Equatable, Sendable {
    case ready
    case permissionMissing
    case appNotRunning
    case needsRecovery(String)
    case selectorsBroken(String)

    public var isReady: Bool { self == .ready }
}

public enum PresenceTargetError: LocalizedError, Equatable {
    case notReady(TargetAvailability)
    case elementNotFound(selector: String, stage: String)
    case activationFailed(control: String)
    case verificationFailed(expected: String, actual: String)
    case clearDurationUnavailable(requested: String)

    public var errorDescription: String? {
        switch self {
        case .notReady(let availability):
            return "Teams is not ready for automation (\(availability))."
        case .elementNotFound(let selector, let stage):
            return "Could not find the Teams control '\(selector)' while \(stage). "
                 + "Teams' interface may have changed."
        case .activationFailed(let control):
            return "The Teams control '\(control)' did not respond to activation."
        case .verificationFailed(let expected, let actual):
            return "Teams did not accept the status. Expected \"\(expected)\" but read back \"\(actual)\"."
        case .clearDurationUnavailable(let requested):
            return "Could not set the Teams clear-duration to '\(requested)'. "
                 + "Teams' interface may have changed."
        }
    }
}
