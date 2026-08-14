import ApplicationServices
import AppKit
import Foundation

// MARK: - Element wrapper

/// A thin, safe wrapper over `AXUIElement`.
///
/// Deliberately has no notion of screen geometry. Nothing in this file — or anywhere in
/// the production automation — reads `AXPosition`, `AXSize` or `AXFrame`, so there is no
/// path by which a coordinate could leak into a click.
public struct AXElement {
    public let raw: AXUIElement

    public init(_ raw: AXUIElement) { self.raw = raw }

    public init(pid: pid_t) { self.raw = AXUIElementCreateApplication(pid) }

    // MARK: Attribute reads

    public func rawAttribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw, name as CFString, &value) == .success else { return nil }
        return value
    }

    public func string(_ name: String) -> String? {
        guard let value = rawAttribute(name) else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    public func bool(_ name: String) -> Bool? {
        (rawAttribute(name) as? NSNumber)?.boolValue
    }

    public var role: String? { string(kAXRoleAttribute as String) }
    public var subrole: String? { string(kAXSubroleAttribute as String) }
    public var title: String? { string(kAXTitleAttribute as String) }
    public var axDescription: String? { string(kAXDescriptionAttribute as String) }
    public var value: String? { string(kAXValueAttribute as String) }
    public var placeholder: String? { string(kAXPlaceholderValueAttribute as String) }
    /// The DOM `id` of the underlying web element. The most stable handle Teams offers.
    public var domIdentifier: String? { string("AXDOMIdentifier") }

    public var children: [AXElement] {
        guard let kids = rawAttribute(kAXChildrenAttribute as String) as? [AXUIElement] else { return [] }
        return kids.map(AXElement.init)
    }

    public var actionNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(raw, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    // MARK: Attribute writes

    /// NOTE: a `.success` return proves only that the call was accepted, NOT that the UI
    /// changed. Chromium routinely returns `.success` and does nothing. Every caller must
    /// verify the effect independently.
    @discardableResult
    public func setAttribute(_ name: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(raw, name as CFString, value)
    }

    @discardableResult
    public func setFocused(_ focused: Bool = true) -> AXError {
        setAttribute(kAXFocusedAttribute as String, focused ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// Same warning as `setAttribute`: `.success` is not evidence of anything.
    @discardableResult
    public func performAction(_ action: String = kAXPressAction as String) -> AXError {
        AXUIElementPerformAction(raw, action as CFString)
    }

    // MARK: Search

    /// Depth-first search for the first descendant matching `predicate`.
    ///
    /// `maxDepth` guards against the pathological trees Chromium can produce mid-render;
    /// the Teams elements we care about sit at depth ~20, so 45 is generous.
    public func firstDescendant(maxDepth: Int = 45,
                                where predicate: (AXElement) -> Bool) -> AXElement? {
        var result: AXElement?
        func walk(_ element: AXElement, _ depth: Int) {
            if result != nil || depth > maxDepth { return }
            if predicate(element) { result = element; return }
            for child in element.children {
                walk(child, depth + 1)
                if result != nil { return }
            }
        }
        walk(self, 0)
        return result
    }

    public func allDescendants(maxDepth: Int = 45, limit: Int = 200,
                               where predicate: (AXElement) -> Bool) -> [AXElement] {
        var found: [AXElement] = []
        func walk(_ element: AXElement, _ depth: Int) {
            if found.count >= limit || depth > maxDepth { return }
            if predicate(element) { found.append(element) }
            for child in element.children { walk(child, depth + 1) }
        }
        walk(self, 0)
        return found
    }

    public func descendantCount(maxDepth: Int = 45, limit: Int = 20_000) -> Int {
        var count = 0
        func walk(_ element: AXElement, _ depth: Int) {
            count += 1
            if count >= limit || depth > maxDepth { return }
            for child in element.children { walk(child, depth + 1) }
        }
        walk(self, 0)
        return count
    }
}

// MARK: - Selectors

/// A named, declarative description of how to find one Teams UI element.
///
/// Selectors are values rather than inline closures so that the selector self-test can
/// enumerate them, report exactly which one broke after a Teams update, and print a
/// human-readable description into the logs.
public struct AXSelector: Sendable {
    public let name: String
    public let describedAs: String
    private let predicate: @Sendable (AXElement) -> Bool

    public init(name: String, describedAs: String,
                predicate: @escaping @Sendable (AXElement) -> Bool) {
        self.name = name
        self.describedAs = describedAs
        self.predicate = predicate
    }

    public func matches(_ element: AXElement) -> Bool { predicate(element) }

    public func find(in root: AXElement) -> AXElement? {
        root.firstDescendant(where: predicate)
    }
}

// MARK: - Polling

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

// MARK: - Targeted synthetic input

/// Key events delivered to one process, never to the global event stream.
///
/// This is what keeps the automation from stealing focus: `CGEvent.postToPid` hands the
/// event straight to Teams, so whatever the user is typing in never sees it, and Teams is
/// never activated. A private event source keeps synthetic modifier state out of the
/// system's, which also matters because the Command modifier otherwise latches (see
/// `replaceText`).
public struct AXKeyboard {
    public enum Key: CGKeyCode {
        case a = 0
        case returnKey = 36
        case space = 49
        case escape = 53
        case delete = 51
    }

    public let pid: pid_t
    private let source: CGEventSource?

    public init(pid: pid_t) {
        self.pid = pid
        self.source = CGEventSource(stateID: .privateState)
    }

    public func send(_ key: Key, flags: CGEventFlags = []) {
        send(keyCode: key.rawValue, flags: flags)
    }

    public func send(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        guard let source else { return }
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: keyCode, keyDown: isDown) else { continue }
            // Flags MUST be set explicitly on every event. The private source latches
            // modifiers from a previous event (notably ⌘ from a select-all), and a leaked
            // Command flag makes Chromium read the keystroke as a shortcut and insert nothing.
            event.flags = flags
            event.postToPid(pid)
        }
    }

    /// Type one grapheme as a unicode key event, independent of the active keymap.
    ///
    /// Astral-plane scalars (emoji above U+FFFF) are silently dropped by this path — see
    /// `UnicodeSanitizer`, which rewrites them before we ever get here.
    public func type(_ character: Character) {
        guard let source else { return }
        var units = Array(String(character).utf16)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: 0, keyDown: isDown) else { continue }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            event.postToPid(pid)
        }
    }
}

// MARK: - Verified activation

public enum ActivationMethod: String, Sendable {
    case axPress = "AXPress"
    case returnKey = "focus+Return"
    case spaceKey = "focus+Space"
}

public enum ActivationOutcome: Sendable, Equatable {
    case succeeded(ActivationMethod)
    case failed

    public var didSucceed: Bool {
        if case .succeeded = self { return true }
        return false
    }
}

public enum AXActivator {
    /// Activate a control and *prove* it did something.
    ///
    /// Phase 0 established that Chromium inside Teams frequently accepts `AXPress`,
    /// returns `.success`, and never runs the DOM handler. After a Teams restart this was
    /// the case for every single control. So activation is defined as "the expected state
    /// transition was observed", not "the API returned success", and we escalate through
    /// verified fallbacks before giving up.
    ///
    /// Key order is role-appropriate: buttons respond to Return, checkboxes to Space.
    @discardableResult
    public static func activate(_ element: AXElement,
                                keyboard: AXKeyboard,
                                timeout: TimeInterval = 4.0,
                                label: String,
                                expecting condition: () -> Bool) -> ActivationOutcome {
        if condition() { return .succeeded(.axPress) }  // already in the desired state

        // 1. AXPress, then verify.
        if element.performAction() == .success,
           AXPoll.wait(timeout: timeout, condition) {
            Log.debug(Log.accessibility, "activate[\(label)]: AXPress worked")
            return .succeeded(.axPress)
        }

        // 2. Semantic focus + a real key event, then verify. Still no coordinates.
        let isCheckbox = element.role == "AXCheckBox"
        let order: [(AXKeyboard.Key, ActivationMethod)] = isCheckbox
            ? [(.space, .spaceKey), (.returnKey, .returnKey)]
            : [(.returnKey, .returnKey), (.space, .spaceKey)]

        for (key, method) in order {
            element.setFocused(true)
            // Give the focus ring a moment to land before the key arrives.
            _ = AXPoll.wait(timeout: 0.6) { element.bool(kAXFocusedAttribute as String) == true }
            keyboard.send(key)
            if AXPoll.wait(timeout: timeout, condition) {
                Log.accessibility.info(
                    "activate[\(label, privacy: .public)]: AXPress was a no-op, \(method.rawValue, privacy: .public) worked")
                return .succeeded(method)
            }
        }

        Log.accessibility.error(
            "activate[\(label, privacy: .public)]: AXPress, Return and Space all failed to produce the expected state")
        return .failed
    }
}
