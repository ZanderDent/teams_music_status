#if os(Windows)
import Foundation

// MARK: - The accessibility vocabulary, on Windows

/// The properties a selector is allowed to match on.
///
/// This file exists only on Windows. On macOS the same three types — `AXSelector`,
/// `AXPoll` and the element being matched — are supplied by `Targets/Teams/AXElement.swift`,
/// which is not compiled here because it imports ApplicationServices and AppKit.
///
/// The point of the exercise is that **`TeamsSelectors.swift` compiles unchanged on both
/// platforms**. Its predicates are written as `{ element in element.role == "AXButton" ... }`
/// with the parameter type inferred: on macOS that infers to `AXElement`, on Windows to
/// `any AccessibleElement`. Both expose the same seven properties, so one file remains the
/// single auditable place Teams UI knowledge lives — which is the property the architecture
/// depends on, and the one that a second, Windows-specific selector file would destroy.
///
/// The vocabulary stays macOS-flavoured on purpose. Teams is the same web application on
/// both platforms, so the *values* — `"Edit status message"`, `"status-note-compose"` —
/// are identical; only the API delivering them differs. The Windows element type maps UI
/// Automation onto these names:
///
/// | This protocol   | macOS                | Windows UI Automation                  |
/// |-----------------|----------------------|----------------------------------------|
/// | `role`          | `AXRole`             | `ControlType`, mapped to AX role names |
/// | `subrole`       | `AXSubrole`          | synthesised (`Window` → `AXApplicationDialog`) |
/// | `title`         | `AXTitle`            | `Name`                                 |
/// | `axDescription` | `AXDescription`      | `Name`                                 |
/// | `value`         | `AXValue`            | `ValuePattern`, falling back to `Name` |
/// | `placeholder`   | `AXPlaceholderValue` | `HelpText`                             |
/// | `domIdentifier` | `AXDOMIdentifier`    | `AutomationId`                         |
///
/// `title` and `axDescription` both map to `Name` because UI Automation has one string
/// where the macOS API has two. That is a widening, not a narrowing: every selector that
/// matched on either still matches.
public protocol AccessibleElement {
    var role: String? { get }
    var subrole: String? { get }
    var title: String? { get }
    var axDescription: String? { get }
    var value: String? { get }
    var placeholder: String? { get }
    /// The DOM `id`. The most stable handle Teams exposes, on both platforms.
    var domIdentifier: String? { get }
}

// MARK: - Selectors

/// A named, self-describing predicate over an accessibility element.
///
/// Mirrors the macOS `AXSelector` exactly, except that it matches `any AccessibleElement`
/// rather than `AXElement`. Carries its own description so a failure can say *which*
/// selector stopped resolving and what it was looking for.
public struct AXSelector: Sendable {
    public let name: String
    public let describedAs: String
    private let predicate: @Sendable (any AccessibleElement) -> Bool

    public init(name: String, describedAs: String,
                predicate: @escaping @Sendable (any AccessibleElement) -> Bool) {
        self.name = name
        self.describedAs = describedAs
        self.predicate = predicate
    }

    public func matches(_ element: any AccessibleElement) -> Bool { predicate(element) }
}

// MARK: - Polling

/// Identical to the macOS `AXPoll`; duplicated rather than shared because the macOS copy
/// lives in a file that cannot be compiled on Windows. Both are pure Foundation.
public enum AXPoll {
    /// Poll `condition` until it is true or `timeout` elapses.
    ///
    /// Used in place of fixed sleeps throughout: the UI settles when it settles, and on a
    /// slower machine (or a busy one) a hardcoded delay is either flaky or wasteful.
    @discardableResult
    public static func wait(timeout: TimeInterval,
                            interval: TimeInterval = 0.08,
                            _ condition: () -> Bool) -> Bool {
        if condition() { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: interval)
            if condition() { return true }
        }
        return false
    }

    /// Poll until `produce` returns non-nil, or `timeout` elapses.
    public static func waitForValue<T>(timeout: TimeInterval,
                                       interval: TimeInterval = 0.08,
                                       _ produce: () -> T?) -> T? {
        if let value = produce() { return value }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: interval)
            if let value = produce() { return value }
        }
        return nil
    }
}
#endif
