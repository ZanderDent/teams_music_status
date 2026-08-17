import Foundation

/// Every piece of Teams UI knowledge in the application, in one auditable place.
///
/// Verified against Microsoft Teams **26183.1901.4874.5228** (Phase 0) and
/// **26198.202.4929.7171** (Phase 1). When a Teams update breaks automation, this file is
/// the only one that should need editing — and `TeamsSelfTest` will name the exact
/// selector that stopped resolving.
///
/// ## Rules
///
/// * Prefer `AXDOMIdentifier` (the DOM `id`) — the most stable handle Teams exposes.
/// * Never use child-index paths. They shift between Teams builds and even between
///   sessions: the profile button moved one level deeper after a restart in Phase 0.
/// * Never use coordinates, geometry, or pixel matching.
/// * Accessible-name matches are English-only. Non-English Teams installs will fail the
///   self-test rather than misbehave, which is the intended outcome.
public enum TeamsSelectors {

    // MARK: Teams is not ready for automation

    /// Window-title fragments that mean Teams is asking the user to authenticate.
    ///
    /// Matched against **top-level window titles only**, which costs one attribute read per
    /// window rather than a walk of the ~4300 node tree, so it is affordable on the hot
    /// path where a full search is not.
    ///
    /// This is a best-effort signal used to *stand down* and to explain why. Nothing
    /// destructive depends on it being right: the safety property — never dismissing UI we
    /// did not open — is enforced in `closeFlyout`, which checks for our own flyout rather
    /// than trusting this. A false positive pauses syncing until the window goes away; a
    /// false negative simply produces the ordinary "couldn't reach the control" failure.
    /// Both are recoverable, and neither touches the user's Teams.
    public static let signInWindowTitleFragments = [
        "sign in",
        "sign out",
        "pick an account",
        "use another account",
        "enter password",
        "verify your identity",
        "we couldn't sign you in",
        "microsoft teams — login",
    ]

    /// True when a window title indicates Teams wants the user, not us.
    public static func titleIndicatesSignIn(_ title: String?) -> Bool {
        guard let title, !title.isEmpty else { return false }
        let lowered = title.lowercased()
        return signInWindowTitleFragments.contains { lowered.contains($0) }
    }

    // MARK: Always present (when the tree is healthy)

    /// Avatar button in the title bar. Opens the profile flyout.
    /// `AXDescription` embeds presence, e.g. `"Your profile, status Available "`.
    public static let profileButton = AXSelector(
        name: "profileButton",
        describedAs: #"AXButton with AXDOMIdentifier "idna-me-control-avatar-trigger", or AXDescription starting "Your profile""#
    ) { element in
        guard element.role == "AXButton" else { return false }
        if element.domIdentifier == "idna-me-control-avatar-trigger" { return true }
        return element.axDescription?.hasPrefix("Your profile") == true
    }

    /// The profile flyout itself, modelled by Teams as an application dialog.
    ///
    /// Matters more than it looks: while this dialog is open Chromium exposes ONLY its
    /// subtree, so the rest of the page — including `profileButton` — vanishes from the
    /// accessibility tree. A flyout left open by a crashed or interrupted run therefore
    /// looks exactly like a dead accessibility tree until it is dismissed.
    public static let profileDialog = AXSelector(
        name: "profileDialog",
        describedAs: #"AXApplicationDialog described "Profile menu""#
    ) { element in
        element.subrole == "AXApplicationDialog"
            && element.axDescription?.localizedCaseInsensitiveContains("profile menu") == true
    }

    // MARK: Present once the profile flyout is open

    /// Read-only rendering of the current status message.
    /// `AXValue` gains a second line ("Display until 8:27 AM") when a clear duration is set.
    public static let statusReadout = AXSelector(
        name: "statusReadout",
        describedAs: #"AXTextField with AXDescription starting "Your current status message""#
    ) { element in
        element.role == "AXTextField"
            && element.axDescription?.hasPrefix("Your current status message") == true
    }

    /// Shown when a status message already exists.
    public static let editStatusButton = AXSelector(
        name: "editStatusButton",
        describedAs: #"AXButton with AXDescription "Edit status message""#
    ) { element in
        element.role == "AXButton" && element.axDescription == "Edit status message"
    }

    /// Shown when a status message already exists.
    public static let deleteStatusButton = AXSelector(
        name: "deleteStatusButton",
        describedAs: #"AXButton with AXDescription "Delete status message""#
    ) { element in
        element.role == "AXButton" && element.axDescription == "Delete status message"
    }

    /// Shown instead of `editStatusButton` when no status message is set.
    public static let setStatusItem = AXSelector(
        name: "setStatusItem",
        describedAs: #"AXMenuItem or AXButton whose name contains "set status message""#
    ) { element in
        guard element.role == "AXMenuItem" || element.role == "AXButton" else { return false }
        let name = (element.axDescription ?? "") + " " + (element.title ?? "")
        return name.localizedCaseInsensitiveContains("set status message")
    }

    // MARK: Present once the status editor is open

    /// The status compose box — a CKEditor 5 contenteditable, not a plain text control.
    ///
    /// `AXDOMIdentifier` survived the 26183 → 26198 update; `AXPlaceholderValue` did NOT
    /// (it became nil), so the fallback matches on `AXDescription` instead.
    public static let composeBox = AXSelector(
        name: "composeBox",
        describedAs: #"element with AXDOMIdentifier "status-note-compose", or AXTextArea described "…mention someone in your status""#
    ) { element in
        if element.domIdentifier == "status-note-compose" { return true }
        guard element.role == "AXTextArea" else { return false }
        let name = (element.axDescription ?? "") + " " + (element.placeholder ?? "")
        return name.contains("mention someone in your status")
    }

    /// Live character counter, e.g. `"19 / 280"`. Source of truth for the length limit.
    public static let characterCounter = AXSelector(
        name: "characterCounter",
        describedAs: #"AXStaticText whose AXValue matches "N / 280""#
    ) { element in
        guard element.role == "AXStaticText", let value = element.value else { return false }
        return value.contains("/ 280")
    }

    /// `AXDOMIdentifier` here looks auto-generated (`rd2`), so the title match is not a
    /// fallback but a co-equal check.
    public static let showWhenMessagedCheckbox = AXSelector(
        name: "showWhenMessagedCheckbox",
        describedAs: #"AXCheckBox titled "Show when people message me" (AXDOMIdentifier "checkbox-rd2")"#
    ) { element in
        guard element.role == "AXCheckBox" else { return false }
        if element.title == "Show when people message me" { return true }
        return element.domIdentifier == "checkbox-rd2"
    }

    /// Title carries the current choice as a suffix, e.g. `"Clear status message after Never"`.
    public static let clearAfterPopup = AXSelector(
        name: "clearAfterPopup",
        describedAs: #"AXPopUpButton whose AXTitle starts "Clear status message after""#
    ) { element in
        element.role == "AXPopUpButton"
            && element.title?.hasPrefix("Clear status message after") == true
    }

    public static let doneButton = AXSelector(
        name: "doneButton",
        describedAs: #"AXButton titled "Done""#
    ) { element in
        element.role == "AXButton" && element.title == "Done"
    }

    /// One option inside the clear-duration popup.
    public static func clearAfterOption(_ label: String) -> AXSelector {
        AXSelector(name: "clearAfterOption(\(label))",
                   describedAs: #"AXMenuItem titled "\#(label)" in the clear-duration popup"#) { element in
            guard element.role == "AXMenuItem" else { return false }
            return element.title == label || element.axDescription == label
        }
    }

    // MARK: Metadata

    /// Observed clear-duration choices. `Never` is the product default.
    public static let clearAfterOptions = ["Never", "Today", "1 hour", "4 hours", "This week", "Custom"]

    /// Teams' own limit, read live from `characterCounter` when available.
    public static let statusCharacterLimit = 280

    /// Selectors the self-test must be able to resolve with the profile flyout open.
    public static let flyoutSelectors: [AXSelector] = [statusReadout]

    /// Selectors the self-test must be able to resolve with the status editor open.
    public static let editorSelectors: [AXSelector] = [
        composeBox, doneButton, clearAfterPopup, characterCounter,
    ]
}
