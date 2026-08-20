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

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* CTEAMSWIN_H */
