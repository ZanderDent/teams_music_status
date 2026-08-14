import Foundation

/// Serialises everything that drives the Microsoft Teams profile flyout.
///
/// The flyout is one piece of global UI, and two callers driving it at once do not
/// interleave harmlessly — one opens it while the other presses Escape, and both then
/// report that the control "did not respond to activation".
///
/// Observed for real during first-run testing: finishing onboarding enabled sync, which
/// started a status write, while the menu-bar panel's `.task` kicked off a selector
/// self-test. The log showed the same message twice on two different threads at the same
/// millisecond, and every Teams interaction failed until both gave up.
///
/// `TeamsAXTarget` and `TeamsSelfTest` are separate objects with separate
/// `TeamsAccessibility` instances, so neither could serialise the other on its own. This
/// is process-wide and recursive, so nested calls inside one operation are fine.
public enum TeamsUI {
    private static let lock = NSRecursiveLock()

    /// Run `body` with exclusive access to the Teams UI.
    public static func exclusive<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Try to take exclusive access without waiting.
    ///
    /// Used by work that is worth skipping rather than queueing — a self-test has no
    /// value if it has to wait behind a status write, because the write already proves
    /// the selectors resolve.
    public static func tryExclusive<T>(_ body: () throws -> T) rethrows -> T? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return try body()
    }
}
