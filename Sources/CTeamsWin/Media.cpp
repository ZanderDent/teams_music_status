// The system media session, via C++/WinRT.
//
// GlobalSystemMediaTransportControlsSession is what Windows itself uses to draw the
// media flyout, so any player that shows up there — Spotify included — is readable with
// no sign-in, no permission prompt and no per-application scripting interface. That makes
// it a straight replacement for the macOS Apple Events path, and a simpler one.

#include "include/CTeamsWin.h"

#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Media.Control.h>

#include <algorithm>
#include <cwctype>
#include <thread>
#include <string>

using namespace winrt;
using namespace winrt::Windows::Media::Control;

namespace {

/// Copies a WinRT string into a fixed UTF-16 buffer, always NUL-terminated.
void copy_out(uint16_t *dst, size_t cap, std::wstring_view src)
{
    const size_t n = (std::min)(src.size(), cap - 1);
    std::copy_n(reinterpret_cast<const uint16_t *>(src.data()), n, dst);
    dst[n] = 0;
}

std::wstring lowered(std::wstring_view s)
{
    std::wstring out(s);
    std::transform(out.begin(), out.end(), out.begin(),
                   [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
    return out;
}

/// Runs `work` on a dedicated multi-threaded-apartment thread and waits for it.
///
/// Not an optimisation — a correctness requirement. These calls block on a WinRT async
/// with `.get()`, and blocking that way on a single-threaded apartment deadlocks: the STA
/// needs to pump messages to complete the operation, and `.get()` never lets it. The tray
/// application's main thread ends up an STA, so calling directly from it hangs the process
/// with no error and no log line.
///
/// Joining a fresh MTA thread each call sidesteps the question entirely: this code no
/// longer cares what apartment the caller happens to be in. The thread costs far less than
/// the media-session round trip it wraps.
template <typename Work>
int32_t on_mta_thread(Work &&work)
{
    int32_t result = TW_ERR_COM;
    std::thread worker([&] {
        try {
            init_apartment(apartment_type::multi_threaded);
        } catch (...) {
            // A fresh thread should never already be in an apartment, but if the runtime
            // disagrees the call below is still worth attempting.
        }
        try { result = work(); }
        catch (...) { result = TW_ERR_COM; }
    });
    worker.join();
    return result;
}

int32_t fill(GlobalSystemMediaTransportControlsSession const &session, TWNowPlaying *out)
{
    try {
        auto props = session.TryGetMediaPropertiesAsync().get();
        auto info = session.GetPlaybackInfo();

        copy_out(out->title,  TW_STR, std::wstring_view(props.Title()));
        copy_out(out->artist, TW_STR, std::wstring_view(props.Artist()));
        copy_out(out->album,  TW_STR, std::wstring_view(props.AlbumTitle()));
        copy_out(out->appId,  TW_STR, std::wstring_view(session.SourceAppUserModelId()));

        out->isPlaying =
            info.PlaybackStatus() ==
            GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing ? 1 : 0;
        return TW_OK;
    } catch (...) {
        return TW_ERR_COM;
    }
}

} // namespace

extern "C" int32_t tw_now_playing_for(const uint16_t *appIdNeedle, TWNowPlaying *out)
{
    if (out == nullptr) return TW_ERR_COM;
    return on_mta_thread([&]() -> int32_t {
    try {
        auto manager = GlobalSystemMediaTransportControlsSessionManager::RequestAsync().get();

        if (appIdNeedle == nullptr || appIdNeedle[0] == 0) {
            auto current = manager.GetCurrentSession();
            if (!current) return TW_ERR_NO_SESSION;
            return fill(current, out);
        }

        const std::wstring needle =
            lowered(reinterpret_cast<const wchar_t *>(appIdNeedle));

        // Prefer a *playing* match: Spotify keeps a session alive while paused, and the
        // "current" session is whatever last had focus, which is not necessarily ours.
        GlobalSystemMediaTransportControlsSession fallback{nullptr};
        auto sessions = manager.GetSessions();
        for (uint32_t i = 0; i < sessions.Size(); ++i) {
            auto s = sessions.GetAt(i);
            const std::wstring id = lowered(std::wstring_view(s.SourceAppUserModelId()));
            if (id.find(needle) == std::wstring::npos) continue;
            if (s.GetPlaybackInfo().PlaybackStatus() ==
                GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing) {
                return fill(s, out);
            }
            if (!fallback) fallback = s;
        }
        if (fallback) return fill(fallback, out);
        return TW_ERR_NO_SESSION;
    } catch (...) {
        return TW_ERR_COM;
    }
    });
}

extern "C" int32_t tw_now_playing(TWNowPlaying *out)
{
    return tw_now_playing_for(nullptr, out);
}
