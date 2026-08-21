import CTeamsWin
import Foundation
import TeamsMusicStatusCore

/// One snapshotted Teams element, presented in the vocabulary `TeamsSelectors` matches on.
///
/// This is the whole reason `TeamsSelectors.swift` needs no Windows variant. Teams 2.x is
/// the same web application on both platforms, so the *values* a selector matches —
/// `"status-note-compose"`, `"Edit status message"` — are identical. Only the API handing
/// them over differs, and that difference is absorbed here.
///
/// It is a value type over a flat snapshot rather than a live handle on purpose: every UI
/// Automation property read is a cross-process call, and matching a dozen selectors against
/// a live tree would cost a round trip per property per node.
public struct UIAElement: AccessibleElement, Sendable {

    public let role: String?
    public let subrole: String?
    public let title: String?
    public let axDescription: String?
    public let value: String?
    public let placeholder: String?
    public let domIdentifier: String?

    init(_ node: TWNode) {
        var node = node
        let name = Self.string(&node.name)
        let uiaValue = Self.string(&node.value)
        let help = Self.string(&node.helpText)
        let automationId = Self.string(&node.automationId)

        self.role = Self.axRole(for: node.controlType)
        self.subrole = node.isDialog == 1 ? "AXApplicationDialog" : nil

        // UI Automation has one name where the macOS API has AXTitle *and* AXDescription.
        // Feeding both from `Name` is a widening, not a narrowing: every selector that
        // matched on either still matches, and no selector distinguishes the two.
        self.title = name.isEmpty ? nil : name
        self.axDescription = name.isEmpty ? nil : name

        // Chromium exposes a ValuePattern on real inputs but not on static text, where the
        // rendered text is the name instead. `characterCounter` matches on the value of a
        // static text node reading "22 / 280", so that fallback is load-bearing.
        //
        // It must *not* apply to edit controls. An edit's name is its accessible label —
        // for the status compose box, the placeholder "Type @ to mention someone in your
        // status". Falling back there makes an empty field read as though it still holds
        // text, so clearing it can never be verified.
        let isEdit = node.controlType == 50004
        let resolved = (uiaValue.isEmpty && !isEdit) ? name : uiaValue
        self.value = resolved.isEmpty ? nil : resolved

        self.placeholder = help.isEmpty ? nil : help
        self.domIdentifier = automationId.isEmpty ? nil : automationId
    }

    /// UI Automation control types, mapped onto the macOS role names the selectors use.
    ///
    /// `ComboBox` maps to `AXPopUpButton` because that is what macOS calls the same
    /// control. The clear-duration control is the awkward one: Windows reports it as a
    /// plain `Button`, so `clearAfterPopup` accepts either role rather than having this
    /// mapping claim a role the element does not have — which would also mislabel the
    /// avatar, and `profileButton` requires `AXButton`.
    private static func axRole(for controlType: Int32) -> String? {
        switch controlType {
        case 50000: return "AXButton"
        case 50002: return "AXCheckBox"
        case 50003: return "AXPopUpButton"
        case 50004: return "AXTextField"
        case 50011: return "AXMenuItem"
        case 50020: return "AXStaticText"
        case 50032: return "AXWindow"
        default: return nil
        }
    }

    /// Reads a fixed-size, NUL-terminated UTF-16 buffer out of the C struct.
    private static func string<T>(_ buffer: inout T) -> String {
        withUnsafeBytes(of: &buffer) { raw in
            let units = raw.bindMemory(to: UInt16.self)
            let end = units.firstIndex(of: 0) ?? units.count
            return String(decoding: units[..<end], as: UTF16.self)
        }
    }
}

// MARK: - Snapshots

/// One bulk read of every Teams element a selector could match.
public struct UIASnapshot: Sendable {
    public let elements: [UIAElement]

    /// Capacity for one snapshot. Teams' full tree is ~4300 nodes, but the shim filters
    /// server-side to the seven control types selectors can match, which in practice
    /// yields a few hundred.
    static let capacity = 800

    public init(elements: [UIAElement]) { self.elements = elements }

    /// Takes a snapshot of the live Teams tree.
    ///
    /// The buffer is allocated raw rather than as `[TWNode](repeating:count:)`. Each node
    /// is ~2.6 KB, so the array form zero-fills two megabytes on every call — and this is
    /// called on a poll loop while waiting for Teams to settle, tens of times per write.
    /// The shim fills every field of the rows it writes and reports how many, so
    /// pre-zeroing buys nothing.
    public static func capture() throws -> UIASnapshot {
        let buffer = UnsafeMutablePointer<TWNode>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        var count: Int32 = 0
        let status = tw_snapshot(buffer, Int32(capacity), &count)
        guard status == TW_OK else { throw TeamsWindowsError(code: status, stage: "snapshot") }

        var elements: [UIAElement] = []
        elements.reserveCapacity(Int(count))
        for index in 0..<Int(count) { elements.append(UIAElement(buffer[index])) }
        return UIASnapshot(elements: elements)
    }

    /// The first element matching `selector`, or nil.
    public func first(_ selector: AXSelector) -> UIAElement? {
        elements.first { selector.matches($0) }
    }

    public func contains(_ selector: AXSelector) -> Bool { first(selector) != nil }
}

// MARK: - Errors

/// A failure from the C shim, carrying the stage it happened at so a log line can say what
/// was being attempted rather than just which code came back.
public struct TeamsWindowsError: LocalizedError, Equatable {
    public let code: Int32
    public let stage: String

    public var errorDescription: String? {
        let reason: String
        switch code {
        case TW_ERR_NO_TEAMS: reason = "Microsoft Teams is not running."
        case TW_ERR_TREE_UNAVAIL: reason = "Teams has not published its accessibility tree."
        case TW_ERR_NOT_FOUND: reason = "The control could not be found."
        case TW_ERR_COM: reason = "A Windows accessibility call failed."
        default: reason = "Unknown error \(code)."
        }
        return "\(reason) (while \(stage))"
    }
}
