// Settings and onboarding windows.
//
// Built from plain Win32 controls rather than a dialog resource, for the same reason the
// tray icon is drawn at run time: SwiftPM cannot compile a .rc file, and a resource-free
// build keeps the executable self-contained.
//
// Both windows run their own modal loop. They are opened from the tray's UI thread, so
// blocking it is correct -- the sync loop lives on another thread and keeps running.

#include "include/CTeamsWin.h"

#include <windows.h>
#include <windowsx.h>

#include <string>

namespace {

// Control ids.
enum : int {
    ID_TEMPLATE = 1001,
    ID_PREVIEW,
    ID_MASK,
    ID_LAUNCH,
    ID_GRACE,
    ID_POLL,
    ID_OK,
    ID_CANCEL,
    ID_ENABLE_SYNC,
};

HFONT ui_font()
{
    static HFONT font = nullptr;
    if (font) return font;

    // Match the shell's font rather than picking one, so the window looks native and
    // follows the user's text-scaling settings.
    NONCLIENTMETRICSW metrics{};
    metrics.cbSize = sizeof(metrics);
    if (SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(metrics), &metrics, 0)) {
        font = CreateFontIndirectW(&metrics.lfMessageFont);
    }
    if (!font) font = static_cast<HFONT>(GetStockObject(DEFAULT_GUI_FONT));
    return font;
}

HWND add(HWND parent, const wchar_t *cls, const wchar_t *text, DWORD style,
         int x, int y, int w, int h, int id)
{
    HWND control = CreateWindowExW(0, cls, text, WS_CHILD | WS_VISIBLE | style,
                                   x, y, w, h, parent,
                                   reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),
                                   GetModuleHandleW(nullptr), nullptr);
    if (control) SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(ui_font()), TRUE);
    return control;
}

std::wstring text_of(HWND control)
{
    const int length = GetWindowTextLengthW(control);
    if (length <= 0) return {};
    std::wstring value(static_cast<size_t>(length), L'\0');
    GetWindowTextW(control, value.data(), length + 1);
    return value;
}

void copy_out(uint16_t *dst, size_t cap, const std::wstring &src)
{
    const size_t n = src.size() < cap - 1 ? src.size() : cap - 1;
    memcpy(dst, src.data(), n * sizeof(uint16_t));
    dst[n] = 0;
}

/// Centres a window on the monitor holding the cursor, which is where the user is looking.
void centre(HWND window)
{
    RECT bounds{};
    GetWindowRect(window, &bounds);
    const int width = bounds.right - bounds.left;
    const int height = bounds.bottom - bounds.top;

    POINT cursor{};
    GetCursorPos(&cursor);
    HMONITOR monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO info{};
    info.cbSize = sizeof(info);
    GetMonitorInfoW(monitor, &info);

    const int x = info.rcWork.left + (info.rcWork.right - info.rcWork.left - width) / 2;
    const int y = info.rcWork.top + (info.rcWork.bottom - info.rcWork.top - height) / 2;
    SetWindowPos(window, HWND_TOP, x, y, 0, 0, SWP_NOSIZE);
}

/// Shared modal loop. Returns the value stored by the window procedure.
int run_modal(HWND window, int *result)
{
    ShowWindow(window, SW_SHOW);
    centre(window);
    SetForegroundWindow(window);

    MSG message;
    while (IsWindow(window) && GetMessageW(&message, nullptr, 0, 0) > 0) {
        // IsDialogMessage gives Tab navigation, Enter for the default button and Escape
        // for cancel, none of which a bare message loop provides.
        if (!IsDialogMessageW(window, &message)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    return *result;
}

// --- settings -------------------------------------------------------------

struct SettingsContext {
    TWSettingsForm *form = nullptr;
    TWPreviewProvider preview = nullptr;
    void *previewContext = nullptr;
    HWND templateEdit = nullptr;
    HWND previewLabel = nullptr;
    HWND maskCheck = nullptr;
    HWND launchCheck = nullptr;
    HWND graceCombo = nullptr;
    int result = 0;
};

const int kGraceSeconds[] = {30, 60, 300, 900, 0 /* Never */};
const wchar_t *kGraceLabels[] = {L"30 seconds", L"1 minute", L"5 minutes", L"15 minutes", L"Never"};

void refresh_preview(SettingsContext *context)
{
    if (!context->preview || !context->previewLabel) return;
    const std::wstring templateText = text_of(context->templateEdit);

    uint16_t rendered[TW_NAME_MAX] = {};
    context->preview(reinterpret_cast<const uint16_t *>(templateText.c_str()),
                     rendered, TW_NAME_MAX, context->previewContext);

    std::wstring shown = L"Preview:  ";
    shown += reinterpret_cast<const wchar_t *>(rendered);
    SetWindowTextW(context->previewLabel, shown.c_str());
}

LRESULT CALLBACK settings_proc(HWND window, UINT message, WPARAM wParam, LPARAM lParam)
{
    auto *context = reinterpret_cast<SettingsContext *>(GetWindowLongPtrW(window, GWLP_USERDATA));

    switch (message) {
    case WM_COMMAND: {
        if (!context) break;
        const int id = LOWORD(wParam);

        if (id == ID_TEMPLATE && HIWORD(wParam) == EN_CHANGE) {
            refresh_preview(context);
            return 0;
        }
        if (id == ID_MASK && HIWORD(wParam) == BN_CLICKED) {
            // The mask affects the rendered text, so the preview has to follow it.
            context->form->maskProfanity =
                Button_GetCheck(context->maskCheck) == BST_CHECKED ? 1 : 0;
            refresh_preview(context);
            return 0;
        }
        if (id == ID_OK) {
            copy_out(context->form->templateText, TW_NAME_MAX, text_of(context->templateEdit));
            context->form->maskProfanity = Button_GetCheck(context->maskCheck) == BST_CHECKED ? 1 : 0;
            context->form->launchAtLogin = Button_GetCheck(context->launchCheck) == BST_CHECKED ? 1 : 0;
            const int index = ComboBox_GetCurSel(context->graceCombo);
            if (index >= 0 && index < static_cast<int>(std::size(kGraceSeconds)))
                context->form->pauseGraceSeconds = kGraceSeconds[index];
            context->result = 1;
            DestroyWindow(window);
            return 0;
        }
        if (id == ID_CANCEL || id == IDCANCEL) {
            context->result = 0;
            DestroyWindow(window);
            return 0;
        }
        break;
    }
    case WM_CLOSE:
        if (context) context->result = 0;
        DestroyWindow(window);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    default:
        break;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

// --- onboarding -----------------------------------------------------------

struct OnboardingContext {
    TWOnboardingForm *form = nullptr;
    HWND syncCheck = nullptr;
    HWND launchCheck = nullptr;
    int result = 0;
};

LRESULT CALLBACK onboarding_proc(HWND window, UINT message, WPARAM wParam, LPARAM lParam)
{
    auto *context = reinterpret_cast<OnboardingContext *>(GetWindowLongPtrW(window, GWLP_USERDATA));

    switch (message) {
    case WM_COMMAND: {
        if (!context) break;
        const int id = LOWORD(wParam);
        if (id == ID_OK) {
            context->form->enableSync = Button_GetCheck(context->syncCheck) == BST_CHECKED ? 1 : 0;
            context->form->launchAtLogin =
                context->launchCheck && Button_GetCheck(context->launchCheck) == BST_CHECKED ? 1 : 0;
            context->result = 1;
            DestroyWindow(window);
            return 0;
        }
        if (id == ID_CANCEL || id == IDCANCEL) {
            context->result = 0;
            DestroyWindow(window);
            return 0;
        }
        break;
    }
    case WM_CLOSE:
        if (context) context->result = 0;
        DestroyWindow(window);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    default:
        break;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

HWND make_window(const wchar_t *className, WNDPROC proc, const wchar_t *title, int width, int height)
{
    const HINSTANCE instance = GetModuleHandleW(nullptr);

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = proc;
    wc.hInstance = instance;
    wc.lpszClassName = className;
    wc.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));  // IDC_ARROW, wide form
    wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    RegisterClassExW(&wc);

    RECT desired{0, 0, width, height};
    const DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU;
    AdjustWindowRect(&desired, style, FALSE);

    return CreateWindowExW(WS_EX_DLGMODALFRAME, className, title, style,
                           CW_USEDEFAULT, CW_USEDEFAULT,
                           desired.right - desired.left, desired.bottom - desired.top,
                           nullptr, nullptr, instance, nullptr);
}

} // namespace

extern "C" int32_t tw_settings_dialog(TWSettingsForm *inout, TWPreviewProvider preview, void *previewContext)
{
    if (inout == nullptr) return 0;

    HWND window = make_window(L"TeamsMusicStatusSettings", settings_proc,
                              L"Teams Music Status — Settings", 460, 300);
    if (window == nullptr) return 0;

    SettingsContext context;
    context.form = inout;
    context.preview = preview;
    context.previewContext = previewContext;
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(&context));

    add(window, L"STATIC", L"Status template", 0, 16, 14, 200, 18, 0);
    context.templateEdit = add(window, L"EDIT",
                               reinterpret_cast<const wchar_t *>(inout->templateText),
                               WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL,
                               16, 34, 420, 24, ID_TEMPLATE);

    add(window, L"STATIC", L"Placeholders:  {track}  {artist}  {artists}  {album}",
        0, 16, 64, 420, 18, 0);

    context.previewLabel = add(window, L"STATIC", L"Preview:", 0, 16, 88, 420, 20, ID_PREVIEW);

    context.maskCheck = add(window, L"BUTTON", L"Mask profanity in track and artist names",
                            BS_AUTOCHECKBOX | WS_TABSTOP, 16, 120, 420, 22, ID_MASK);
    Button_SetCheck(context.maskCheck, inout->maskProfanity ? BST_CHECKED : BST_UNCHECKED);

    context.launchCheck = add(window, L"BUTTON", L"Start when I sign in to Windows",
                              BS_AUTOCHECKBOX | WS_TABSTOP, 16, 146, 420, 22, ID_LAUNCH);
    Button_SetCheck(context.launchCheck, inout->launchAtLogin ? BST_CHECKED : BST_UNCHECKED);
    if (!inout->launchAtLoginSupported) {
        EnableWindow(context.launchCheck, FALSE);
        SetWindowTextW(context.launchCheck,
                       L"Start when I sign in to Windows  (installed builds only)");
    }

    add(window, L"STATIC", L"Restore my previous status after", 0, 16, 180, 200, 18, 0);
    context.graceCombo = add(window, L"COMBOBOX", nullptr,
                             CBS_DROPDOWNLIST | WS_TABSTOP | WS_VSCROLL,
                             220, 176, 160, 200, ID_GRACE);
    int selected = 2;
    for (int i = 0; i < static_cast<int>(std::size(kGraceLabels)); ++i) {
        ComboBox_AddString(context.graceCombo, kGraceLabels[i]);
        if (kGraceSeconds[i] == inout->pauseGraceSeconds) selected = i;
    }
    ComboBox_SetCurSel(context.graceCombo, selected);

    add(window, L"BUTTON", L"Save", BS_DEFPUSHBUTTON | WS_TABSTOP, 250, 222, 90, 30, ID_OK);
    add(window, L"BUTTON", L"Cancel", WS_TABSTOP, 346, 222, 90, 30, ID_CANCEL);

    refresh_preview(&context);
    return run_modal(window, &context.result);
}

extern "C" int32_t tw_onboarding_dialog(TWOnboardingForm *inout)
{
    if (inout == nullptr) return 0;

    HWND window = make_window(L"TeamsMusicStatusWelcome", onboarding_proc,
                              L"Teams Music Status", 470, 330);
    if (window == nullptr) return 0;

    OnboardingContext context;
    context.form = inout;
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(&context));

    add(window, L"STATIC", L"Show what you are listening to as your Teams status.",
        0, 16, 16, 430, 20, 0);
    add(window, L"STATIC",
        L"It sets your status message the way you would by hand — through the profile "
        L"menu — in the background. Teams is never brought to the front, and your "
        L"previous status is put back when you stop.",
        0, 16, 42, 430, 56, 0);

    // Two readiness lines, so a user whose setup is incomplete finds out here rather
    // than from a status that silently never updates.
    std::wstring teamsLine = inout->teamsReady
        ? L"✓  Microsoft Teams "
        : L"✗  Microsoft Teams is not running";
    if (inout->teamsReady) teamsLine += reinterpret_cast<const wchar_t *>(inout->teamsVersion);
    add(window, L"STATIC", teamsLine.c_str(), 0, 16, 112, 430, 20, 0);

    std::wstring playerLine = (inout->playerReady ? L"✓  " : L"✗  ");
    playerLine += reinterpret_cast<const wchar_t *>(inout->playerState);
    add(window, L"STATIC", playerLine.c_str(), 0, 16, 134, 430, 20, 0);

    context.syncCheck = add(window, L"BUTTON", L"Start syncing my status now",
                            BS_AUTOCHECKBOX | WS_TABSTOP, 16, 172, 430, 22, ID_ENABLE_SYNC);
    Button_SetCheck(context.syncCheck, BST_CHECKED);

    context.launchCheck = add(window, L"BUTTON", L"Start when I sign in to Windows",
                              BS_AUTOCHECKBOX | WS_TABSTOP, 16, 198, 430, 22, ID_LAUNCH);
    Button_SetCheck(context.launchCheck, inout->launchAtLogin ? BST_CHECKED : BST_UNCHECKED);
    if (!inout->launchAtLoginSupported) EnableWindow(context.launchCheck, FALSE);

    add(window, L"STATIC",
        L"You can change any of this later from the icon in the notification area.",
        0, 16, 232, 430, 20, 0);

    add(window, L"BUTTON", L"Get started", BS_DEFPUSHBUTTON | WS_TABSTOP, 250, 258, 100, 30, ID_OK);
    add(window, L"BUTTON", L"Not now", WS_TABSTOP, 356, 258, 90, 30, ID_CANCEL);

    return run_modal(window, &context.result);
}

extern "C" void tw_message_box(const uint16_t *title, const uint16_t *body, int32_t isError)
{
    MessageBoxW(nullptr,
                reinterpret_cast<const wchar_t *>(body),
                reinterpret_cast<const wchar_t *>(title),
                MB_OK | (isError ? MB_ICONERROR : MB_ICONINFORMATION));
}
