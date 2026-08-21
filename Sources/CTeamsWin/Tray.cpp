// The notification-area shell.
//
// A hidden window owns the tray icon and pumps the message loop. Swift builds the menu and
// receives command ids; it never sees a window procedure or a stateful C callback.
//
// The icon is drawn at run time with GDI rather than loaded from a resource. SwiftPM has no
// way to compile a .rc file, and a run-time icon keeps the executable self-contained --
// there is no .ico to lose, and the two states differ only by colour.

#include "include/CTeamsWin.h"

#include <windows.h>
#include <shellapi.h>

#include <string>

namespace {

constexpr UINT WM_TRAY_CALLBACK = WM_APP + 1;
constexpr UINT WM_TRAY_FORWARD  = WM_APP + 2;   // marshals a call onto the UI thread
constexpr UINT TRAY_ICON_ID     = 1;

struct TrayState {
    HWND window = nullptr;
    HMENU menu = nullptr;
    NOTIFYICONDATAW icon{};
    HICON icons[3]{};

    TWCommandHandler handler = nullptr;
    void *handlerContext = nullptr;
    TWCommandHandler menuBuilder = nullptr;
    void *menuBuilderContext = nullptr;

    /// Explorer can restart, taking every tray icon with it. It then broadcasts this
    /// message so applications can put theirs back. Without handling it the app keeps
    /// running with no icon and no way to reach it, which reads as a crash.
    UINT taskbarCreated = 0;

    bool running = false;
};

TrayState &tray()
{
    static TrayState state;
    return state;
}

/// Draws a music note into a 32x32 icon.
///
/// Colour carries the state: muted when idle, accented when syncing, red when something
/// needs attention. Drawn rather than shipped so the binary has no external dependency.
HICON make_icon(COLORREF colour)
{
    const int size = 32;
    HDC screen = GetDC(nullptr);
    HDC memory = CreateCompatibleDC(screen);

    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = size;
    info.bmiHeader.biHeight = -size;      // top-down
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;

    void *bits = nullptr;
    HBITMAP colourBitmap = CreateDIBSection(memory, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
    HGDIOBJ oldBitmap = SelectObject(memory, colourBitmap);

    // Fully transparent to start with; only the glyph's pixels get an alpha.
    if (bits) memset(bits, 0, static_cast<size_t>(size) * size * 4);

    HFONT font = CreateFontW(30, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE,
                             DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                             CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI Symbol");
    HGDIOBJ oldFont = SelectObject(memory, font);
    SetBkMode(memory, TRANSPARENT);
    SetTextColor(memory, colour);

    RECT bounds{0, 0, size, size};
    DrawTextW(memory, L"♪", 1, &bounds, DT_CENTER | DT_VCENTER | DT_SINGLELINE);

    // GDI text drawing does not set alpha, so every pixel it touched is left at zero and
    // would be invisible. Recover the glyph by treating any pixel with colour as opaque.
    if (bits) {
        auto *pixels = static_cast<uint8_t *>(bits);
        for (int i = 0; i < size * size; ++i) {
            uint8_t *p = pixels + i * 4;
            if (p[0] || p[1] || p[2]) p[3] = 255;
        }
    }

    SelectObject(memory, oldFont);
    DeleteObject(font);

    HBITMAP mask = CreateBitmap(size, size, 1, 1, nullptr);
    ICONINFO iconInfo{};
    iconInfo.fIcon = TRUE;
    iconInfo.hbmMask = mask;
    iconInfo.hbmColor = colourBitmap;
    HICON icon = CreateIconIndirect(&iconInfo);

    SelectObject(memory, oldBitmap);
    DeleteObject(mask);
    DeleteObject(colourBitmap);
    DeleteDC(memory);
    ReleaseDC(nullptr, screen);
    return icon;
}

void show_menu(HWND window)
{
    auto &t = tray();

    // Rebuilt every time: what is playing, and whether syncing is on, change between
    // right-clicks.
    if (t.menuBuilder) t.menuBuilder(0, t.menuBuilderContext);
    if (!t.menu) return;

    POINT cursor{};
    GetCursorPos(&cursor);

    // Required, and easy to miss: without it the menu does not dismiss when the user
    // clicks elsewhere, and stays on screen until something else takes the foreground.
    SetForegroundWindow(window);

    const UINT chosen = TrackPopupMenu(t.menu,
                                       TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY,
                                       cursor.x, cursor.y, 0, window, nullptr);
    PostMessageW(window, WM_NULL, 0, 0);

    if (chosen != 0 && t.handler) t.handler(static_cast<int32_t>(chosen), t.handlerContext);
}

LRESULT CALLBACK wnd_proc(HWND window, UINT message, WPARAM wParam, LPARAM lParam)
{
    auto &t = tray();

    if (message == t.taskbarCreated && t.taskbarCreated != 0) {
        Shell_NotifyIconW(NIM_ADD, &t.icon);
        return 0;
    }

    switch (message) {
    case WM_TRAY_CALLBACK:
        switch (LOWORD(lParam)) {
        case WM_RBUTTONUP:
        case WM_CONTEXTMENU:
            show_menu(window);
            return 0;
        case WM_LBUTTONDBLCLK:
            if (t.handler) t.handler(1 /* primary action */, t.handlerContext);
            return 0;
        default:
            return 0;
        }

    case WM_TRAY_FORWARD:
        if (t.handler) t.handler(static_cast<int32_t>(wParam), t.handlerContext);
        return 0;

    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;

    default:
        return DefWindowProcW(window, message, wParam, lParam);
    }
}

} // namespace

extern "C" int32_t tw_tray_init(const uint16_t *tooltip, TWCommandHandler handler, void *context)
{
    auto &t = tray();
    if (t.window != nullptr) return TW_OK;

    t.handler = handler;
    t.handlerContext = context;

    const HINSTANCE instance = GetModuleHandleW(nullptr);

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = instance;
    wc.lpszClassName = L"TeamsMusicStatusTray";
    if (RegisterClassExW(&wc) == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
        return TW_ERR_COM;

    t.window = CreateWindowExW(0, L"TeamsMusicStatusTray", L"Teams Music Status",
                               0, 0, 0, 0, 0, nullptr, nullptr, instance, nullptr);
    if (t.window == nullptr) return TW_ERR_COM;

    t.taskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");

    t.icons[TW_ICON_IDLE]    = make_icon(RGB(128, 128, 128));
    t.icons[TW_ICON_ACTIVE]  = make_icon(RGB(98, 100, 167));   // Teams purple
    t.icons[TW_ICON_PROBLEM] = make_icon(RGB(196, 43, 28));

    t.icon.cbSize = sizeof(t.icon);
    t.icon.hWnd = t.window;
    t.icon.uID = TRAY_ICON_ID;
    t.icon.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    t.icon.uCallbackMessage = WM_TRAY_CALLBACK;
    t.icon.hIcon = t.icons[TW_ICON_IDLE];
    if (tooltip) wcsncpy_s(t.icon.szTip, reinterpret_cast<const wchar_t *>(tooltip), _TRUNCATE);

    return Shell_NotifyIconW(NIM_ADD, &t.icon) ? TW_OK : TW_ERR_COM;
}

extern "C" void tw_tray_menu_begin(void)
{
    auto &t = tray();
    if (t.menu) DestroyMenu(t.menu);
    t.menu = CreatePopupMenu();
}

extern "C" void tw_tray_menu_add(int32_t commandId, const uint16_t *label,
                                 int32_t checked, int32_t enabled)
{
    auto &t = tray();
    if (!t.menu || label == nullptr) return;

    UINT flags = MF_STRING;
    if (checked) flags |= MF_CHECKED;
    if (!enabled) flags |= MF_GRAYED;
    AppendMenuW(t.menu, flags, static_cast<UINT_PTR>(commandId),
                reinterpret_cast<const wchar_t *>(label));
}

extern "C" void tw_tray_menu_add_separator(void)
{
    auto &t = tray();
    if (t.menu) AppendMenuW(t.menu, MF_SEPARATOR, 0, nullptr);
}

extern "C" void tw_tray_set_menu_builder(TWCommandHandler builder, void *context)
{
    auto &t = tray();
    t.menuBuilder = builder;
    t.menuBuilderContext = context;
}

extern "C" int32_t tw_tray_set_tooltip(const uint16_t *tooltip)
{
    auto &t = tray();
    if (t.window == nullptr || tooltip == nullptr) return TW_ERR_COM;
    t.icon.uFlags = NIF_TIP;
    wcsncpy_s(t.icon.szTip, reinterpret_cast<const wchar_t *>(tooltip), _TRUNCATE);
    const BOOL ok = Shell_NotifyIconW(NIM_MODIFY, &t.icon);
    t.icon.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    return ok ? TW_OK : TW_ERR_COM;
}

extern "C" int32_t tw_tray_set_icon(int32_t state)
{
    auto &t = tray();
    if (t.window == nullptr) return TW_ERR_COM;
    if (state < 0 || state > TW_ICON_PROBLEM) state = TW_ICON_IDLE;

    t.icon.uFlags = NIF_ICON;
    t.icon.hIcon = t.icons[state];
    const BOOL ok = Shell_NotifyIconW(NIM_MODIFY, &t.icon);
    t.icon.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    return ok ? TW_OK : TW_ERR_COM;
}

extern "C" int32_t tw_tray_notify(const uint16_t *title, const uint16_t *body)
{
    auto &t = tray();
    if (t.window == nullptr) return TW_ERR_COM;

    t.icon.uFlags = NIF_INFO;
    t.icon.dwInfoFlags = NIIF_NONE;
    if (title) wcsncpy_s(t.icon.szInfoTitle, reinterpret_cast<const wchar_t *>(title), _TRUNCATE);
    if (body) wcsncpy_s(t.icon.szInfo, reinterpret_cast<const wchar_t *>(body), _TRUNCATE);
    const BOOL ok = Shell_NotifyIconW(NIM_MODIFY, &t.icon);
    t.icon.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    return ok ? TW_OK : TW_ERR_COM;
}

extern "C" int32_t tw_tray_post_to_ui(int32_t commandId)
{
    auto &t = tray();
    if (t.window == nullptr) return TW_ERR_COM;
    return PostMessageW(t.window, WM_TRAY_FORWARD, static_cast<WPARAM>(commandId), 0)
        ? TW_OK : TW_ERR_COM;
}

extern "C" int32_t tw_tray_run(void)
{
    auto &t = tray();
    if (t.window == nullptr) return TW_ERR_COM;
    t.running = true;

    MSG message;
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }

    t.running = false;
    Shell_NotifyIconW(NIM_DELETE, &t.icon);
    return TW_OK;
}

extern "C" void tw_tray_quit(void)
{
    auto &t = tray();
    if (t.window) PostMessageW(t.window, WM_CLOSE, 0, 0);
}

extern "C" int32_t tw_single_instance_acquire(const uint16_t *name)
{
    if (name == nullptr) return 0;
    // Deliberately leaked: the mutex must outlive this call and is released when the
    // process exits, which is exactly the lifetime wanted.
    HANDLE mutex = CreateMutexW(nullptr, TRUE, reinterpret_cast<const wchar_t *>(name));
    if (mutex == nullptr) return 0;
    return GetLastError() == ERROR_ALREADY_EXISTS ? 0 : 1;
}

extern "C" int32_t tw_shell_open(const uint16_t *target)
{
    if (target == nullptr) return TW_ERR_COM;
    const HINSTANCE result = ShellExecuteW(nullptr, L"open",
                                           reinterpret_cast<const wchar_t *>(target),
                                           nullptr, nullptr, SW_SHOWNORMAL);
    return reinterpret_cast<INT_PTR>(result) > 32 ? TW_OK : TW_ERR_COM;
}
