/*
 * CTeamsWin — a flat C ABI over the three Windows APIs the port needs.
 *
 * Swift on Windows can call C directly but reaching COM (UI Automation, MSAA) and WinRT
 * (the system media session) from Swift means hand-rolling vtable dispatch. Wrapping them
 * in C++ and exposing a C surface keeps that mess in one auditable file and lets the Swift
 * side stay ordinary Swift.
 *
 * Strings are UTF-16 (`uint16_t`), which is what both Windows and Swift's String already
 * speak, so no transcoding happens at the boundary.
 *
 * Every function returns 0 on success and a non-zero TW_ERR_* on failure. Nothing here
 * reports success it has not observed — that rule is enforced on the Swift side, but the
 * primitives are shaped to make it possible: activation is separate from verification.
 */
#ifndef CTEAMSWIN_H
#define CTEAMSWIN_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TW_OK                 0
#define TW_ERR_NO_TEAMS       1  /* Teams is not running, or has no window */
#define TW_ERR_NO_SESSION     2  /* nothing is playing — a normal state, not an error */
#define TW_ERR_COM            3  /* a COM/WinRT call failed */
#define TW_ERR_NOT_FOUND      4  /* the requested element is not in the tree */
#define TW_ERR_TREE_UNAVAIL   5  /* Chromium has not published the web content tree */

/* --- now playing -------------------------------------------------------- */

#define TW_STR 512

typedef struct {
    uint16_t title[TW_STR];
    uint16_t artist[TW_STR];
    uint16_t album[TW_STR];
    uint16_t appId[TW_STR];
    int32_t  isPlaying;   /* 1 playing, 0 paused or stopped */
} TWNowPlaying;

/*
 * Reads the current system media session — the Windows counterpart of the macOS
 * AppleScript local source, and strictly richer: it reports the album and needs no
 * permission grant.
 *
 * Returns TW_ERR_NO_SESSION when nothing is playing, which the caller must treat as a
 * normal state rather than a failure.
 */
int32_t tw_now_playing(TWNowPlaying *out);

/*
 * As above, but restricted to sessions whose source application id contains `appIdNeedle`
 * (case-insensitive) — e.g. u"Spotify". Lets the product follow one player rather than
 * whatever last made a sound.
 */
int32_t tw_now_playing_for(const uint16_t *appIdNeedle, TWNowPlaying *out);

/* --- window health and repair -------------------------------------------- */

/*
 * The states Teams can be in, in the order the repair loop escalates through them.
 * Mirrors the macOS health model in TeamsAccessibility.
 */
#define TW_HEALTH_OK            0
#define TW_HEALTH_NOT_RUNNING   1
#define TW_HEALTH_NO_WINDOW     2
#define TW_HEALTH_MINIMIZED     3
#define TW_HEALTH_TREE_UNAVAIL  4

int32_t tw_health(void);

/*
 * Un-minimises and orders the Teams window in *without* activating it.
 *
 * SW_RESTORE would activate, which the product may not do. SW_SHOWNOACTIVATE restores a
 * minimised window and leaves the foreground alone. This matters beyond politeness: a
 * minimised Chromium window is treated as occluded and silently discards interactions, so
 * the window has to come back before anything else will work -- the same reason the macOS
 * implementation follows un-minimising with AXRaise.
 */
int32_t tw_window_restore(void);

/*
 * Minimises the Teams window. Used only by the acceptance gate, to *create* the state
 * that tw_window_restore then has to recover from. The product never calls this.
 */
int32_t tw_window_minimize(void);

/* The installed Teams build, e.g. "26213.1006.5014.9784". Empty if it cannot be read. */
int32_t tw_teams_version(uint16_t *out, int32_t capacity);

/*
 * Every top-level Teams window title, newline-separated.
 *
 * Used to notice that Teams is asking the user to authenticate, so the app can stand down
 * instead of driving a login sheet. Titles only: one string read per window, rather than a
 * walk of the tree, so it is cheap enough for the polling path.
 */
int32_t tw_teams_window_titles(uint16_t *out, int32_t capacity);

/* Whether a Teams window currently has the foreground — i.e. the user is working in it. */
int32_t tw_teams_is_frontmost(void);

/*
 * The title of the window that currently has the foreground.
 *
 * Instrumentation for the acceptance gate, which has to *prove* the frontmost window is
 * unchanged across every interaction. The product itself never needs this.
 */
int32_t tw_foreground_title(uint16_t *out, int32_t capacity);

/*
 * Brings this process's own console window to the foreground.
 *
 * Test scaffolding, and the only place in this file that deliberately changes activation.
 * A "focus was preserved" assertion is worthless if Teams already had the foreground when
 * the case started, so the gate parks focus somewhere that is definitely not Teams first.
 */
int32_t tw_park_focus(void);

/* --- the Teams accessibility tree ---------------------------------------- */

#define TW_NAME_MAX  512
#define TW_ID_MAX    160

/*
 * One element, flattened. Snapshotting into plain structs rather than handing Swift live
 * COM pointers is deliberate: every UI Automation property read is a cross-process call,
 * and matching a dozen selectors against a live tree costs a round trip per property per
 * node. One cached bulk read is the difference between ~600ms and ~30ms.
 */
typedef struct {
    int32_t  controlType;     /* UIA control type id, e.g. 50000 = Button */
    int32_t  isDialog;        /* Window control types that model a Teams flyout */
    uint16_t name[TW_NAME_MAX];
    uint16_t automationId[TW_ID_MAX];
    uint16_t value[TW_NAME_MAX];
    uint16_t helpText[TW_ID_MAX];
} TWNode;

/*
 * Acquires the Teams window and switches Chromium's web-content accessibility on.
 *
 * Chromium keeps the renderer tree off until it believes an assistive technology is
 * present. Obtaining an IAccessible for the render widget is not enough on its own — the
 * tree only materialises once it is *read through*, which is the same thing the macOS
 * implementation discovered about walking the WebView helper processes.
 *
 * Safe to call repeatedly; the tree can lapse and this re-establishes it.
 */
int32_t tw_open(void);
void    tw_close(void);

/* Fills `out` with up to `capacity` elements. Only control types selectors can match are
 * returned, which keeps a ~4300-node Teams tree down to a few hundred rows. */
int32_t tw_snapshot(TWNode *out, int32_t capacity, int32_t *count);

/*
 * Presses the element whose accessible name begins with `namePrefix`, via MSAA.
 *
 * MSAA specifically, and not UI Automation. Measured against live Teams: UIA's SetFocus
 * and ExpandCollapsePattern.Expand both work but pull the Teams window to the foreground,
 * and UIA's LegacyIAccessible DoDefaultAction does not steal focus but silently does
 * nothing. Navigating MSAA directly and calling accDoDefaultAction is the only route that
 * both works and leaves the foreground window alone.
 *
 * Returning TW_OK means the call was delivered, never that anything happened. Chromium
 * routinely accepts an action and does nothing; the caller must observe the expected state
 * change itself.
 */
int32_t tw_msaa_press(const uint16_t *namePrefix);

/*
 * Moves DOM focus to the element whose accessible name begins with `namePrefix`, via MSAA
 * accSelect(SELFLAG_TAKEFOCUS).
 *
 * Necessary because posted keys go to whatever holds the caret, and a Teams surface left
 * open by an interrupted run has no focus at all -- at which point Backspace and Escape
 * both land nowhere and the app cannot type into, clear, or even close the editor. That is
 * an unrecoverable state, and it was reachable in practice.
 *
 * MSAA specifically, again: UI Automation's SetFocus does the same job and drags the Teams
 * window to the foreground, which is the one thing this product may not do.
 *
 * Delivered, not confirmed. Verify by observing what the keys then do.
 */
int32_t tw_msaa_focus(const uint16_t *namePrefix);

/*
 * Posts a key to the renderer without activating Teams — the counterpart of the macOS
 * CGEvent.postToPid path.
 *
 * Two details are load-bearing. The message must go to the Chrome_WidgetWin_1 browser
 * widget, not the Chrome_RenderWidgetHostHWND that carries accessibility; and lParam must
 * carry the real scan code, because Chromium reads it and silently discards a key posted
 * with a zero lParam.
 */
int32_t tw_post_key(int32_t virtualKey);

/*
 * Sets the text of the element with `automationId` via UI Automation's ValuePattern.
 *
 * The status compose box is a CKEditor contenteditable rather than a plain text control,
 * so this is not guaranteed to take, and it may set the DOM text without notifying the
 * editor's own model. Verify by reading the value back before trusting it, and fall back
 * to tw_type_text when it does not stick.
 */
int32_t tw_set_value(const uint16_t *automationId, const uint16_t *text);

/*
 * Types `text` into whatever currently holds the caret, one WM_CHAR per UTF-16 unit,
 * posted to the browser widget so Teams is never activated.
 *
 * Requires the caret to already be in the intended field: there is no way to move DOM
 * focus on Windows without activating the window, so this is only usable at a point where
 * Teams has focused the field itself — which it does when the status editor opens.
 */
int32_t tw_type_text(const uint16_t *text);

/*
 * Empties the focused field by moving the caret to the end and pressing Backspace
 * `count` times.
 *
 * Blunt, and deliberately so. Ctrl+A cannot be delivered this way: Chromium derives
 * modifier state from the receiving thread's keyboard, which a posted WM_KEYDOWN for
 * VK_CONTROL does not change, so a posted Ctrl+A arrives as a plain "a" and *inserts* a
 * character instead of selecting anything. Backspace needs no modifier, so it works.
 *
 * `count` should be the field's current length plus a little slack; the caller verifies
 * the field is actually empty afterwards rather than assuming.
 */
int32_t tw_clear_field(int32_t count);

#define TW_VK_ESCAPE 0x1B
#define TW_VK_RETURN 0x0D
#define TW_VK_SPACE  0x20
#define TW_VK_DELETE 0x2E
#define TW_VK_BACK   0x08

/* --- tray shell ----------------------------------------------------------- */

/*
 * The notification-area icon and its menu.
 *
 * A hidden window owns the icon and pumps the message loop; Swift supplies the menu and
 * receives a command id when something is clicked. Keeping the Win32 plumbing here means
 * the Swift side never touches a window procedure or a C function pointer with state.
 */

typedef void (*TWCommandHandler)(int32_t commandId, void *context);

/* Icon states, so the tray can show at a glance whether syncing is live. */
#define TW_ICON_IDLE     0
#define TW_ICON_ACTIVE   1
#define TW_ICON_PROBLEM  2

/*
 * Creates the hidden window and adds the icon. Call once, before tw_tray_run.
 * `tooltip` is what appears on hover.
 */
int32_t tw_tray_init(const uint16_t *tooltip, TWCommandHandler handler, void *context);

/* Replaces the whole menu. Build it fresh each time it is about to be shown. */
void tw_tray_menu_begin(void);
void tw_tray_menu_add(int32_t commandId, const uint16_t *label, int32_t checked, int32_t enabled);
void tw_tray_menu_add_separator(void);

/*
 * Called just before the menu is displayed, so the caller can rebuild it with current
 * state -- what is playing changes between right-clicks.
 */
void tw_tray_set_menu_builder(TWCommandHandler builder, void *context);

int32_t tw_tray_set_tooltip(const uint16_t *tooltip);
int32_t tw_tray_set_icon(int32_t state);

/* A balloon notification. Used sparingly -- only for things the user must know. */
int32_t tw_tray_notify(const uint16_t *title, const uint16_t *body);

/* Runs the message loop. Returns when tw_tray_quit is called. */
int32_t tw_tray_run(void);
void    tw_tray_quit(void);

/*
 * Marshals a call onto the UI thread.
 *
 * The sync loop runs on its own thread and must not touch the tray directly: Shell_NotifyIcon
 * from a non-UI thread is a source of intermittent, unreproducible failures.
 */
int32_t tw_tray_post_to_ui(int32_t commandId);

/* --- settings and onboarding --------------------------------------------- */

/*
 * Renders a template so the settings window can show what Teams will actually receive.
 *
 * The preview is not cosmetic: profanity masking and Unicode sanitising both change the
 * text, so a user editing a template with no preview cannot tell why their status looks
 * different from what they typed.
 */
typedef void (*TWPreviewProvider)(const uint16_t *templateText,
                                  uint16_t *out, int32_t capacity, void *context);

typedef struct {
    uint16_t templateText[TW_NAME_MAX];
    int32_t  maskProfanity;
    int32_t  launchAtLogin;
    /* False when running from the build directory, where a startup entry would rot. */
    int32_t  launchAtLoginSupported;
    int32_t  pauseGraceSeconds;
    int32_t  pollSeconds;
} TWSettingsForm;

/* Modal. Returns 1 when the user saved, 0 when they cancelled or closed the window. */
int32_t tw_settings_dialog(TWSettingsForm *inout, TWPreviewProvider preview, void *context);

typedef struct {
    uint16_t teamsVersion[TW_ID_MAX];
    uint16_t playerState[TW_NAME_MAX];
    int32_t  teamsReady;
    int32_t  playerReady;
    /* Out: what the user chose. */
    int32_t  enableSync;
    int32_t  launchAtLogin;
    int32_t  launchAtLoginSupported;
} TWOnboardingForm;

/* Modal. Returns 1 when the user finished setup, 0 when they closed the window. */
int32_t tw_onboarding_dialog(TWOnboardingForm *inout);

/* A modal message box. Used for errors the user has to see. */
void tw_message_box(const uint16_t *title, const uint16_t *body, int32_t isError);

/* --- windows -------------------------------------------------------------- */

/*
 * Ensures only one copy of the app is running, and returns 0 if another already holds the
 * name. A second instance would fight the first over the same Teams status.
 */
int32_t tw_single_instance_acquire(const uint16_t *name);

/*
 * Serialises Teams UI access across *processes*.
 *
 * The profile flyout is one piece of global UI. An in-process lock is not enough: the tray
 * application and the diagnostics CLI are separate processes, and running `tmswinctl gate`
 * while the app is syncing means one opens the flyout while the other presses Escape.
 * Both then report that the control "did not respond to activation" -- which looks like a
 * broken selector rather than two programs fighting.
 *
 * Returns TW_OK when the lock is held, TW_ERR_BUSY when the timeout elapsed.
 * Every successful lock must be matched by tw_ui_unlock.
 */
int32_t tw_ui_lock(int32_t timeoutMs);
void    tw_ui_unlock(void);

#define TW_ERR_BUSY 6

/* Opens a path or URL with the shell -- the log folder, or the project page. */
int32_t tw_shell_open(const uint16_t *target);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* CTEAMSWIN_H */
