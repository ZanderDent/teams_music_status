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

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* CTEAMSWIN_H */
