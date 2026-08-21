// The Teams accessibility tree on Windows.
//
// Reading is done with UI Automation, which is fast when its cache is used and hands over
// the DOM id straight out of AutomationId. Acting is done with MSAA, which is the only
// route measured to press a Teams control without dragging the window to the foreground.
// Keys go to the browser widget by PostMessage, which Chromium processes while unfocused.
//
// Nothing here reports that an interaction worked -- only that it was delivered. Chromium
// accepts actions and discards them routinely, so every caller has to observe the state
// change for itself. That rule is enforced on the Swift side; this file keeps the
// primitives honest by never inferring success.

#include "include/CTeamsWin.h"

#include <windows.h>
#include <oleacc.h>
#include <uiautomation.h>
#include <tlhelp32.h>

#include <winrt/base.h>

#include <algorithm>
#include <string>
#include <mutex>
#include <vector>

namespace {

// --- window discovery ----------------------------------------------------

struct TeamsWindows {
    HWND top = nullptr;
    std::vector<HWND> renderWidgets;  // Chrome_RenderWidgetHostHWND -- accessibility
    std::vector<HWND> inputTargets;   // Chrome_WidgetWin_1 -- keyboard input
};

std::wstring class_of(HWND h)
{
    wchar_t buf[256] = {};
    GetClassNameW(h, buf, 256);
    return buf;
}

void collect(HWND parent, TeamsWindows &out)
{
    EnumChildWindows(parent, [](HWND child, LPARAM param) -> BOOL {
        auto &acc = *reinterpret_cast<TeamsWindows *>(param);
        const std::wstring cls = class_of(child);
        if (cls == L"Chrome_RenderWidgetHostHWND") {
            if (std::find(acc.renderWidgets.begin(), acc.renderWidgets.end(), child) == acc.renderWidgets.end())
                acc.renderWidgets.push_back(child);
        } else if (cls == L"Chrome_WidgetWin_1") {
            if (std::find(acc.inputTargets.begin(), acc.inputTargets.end(), child) == acc.inputTargets.end())
                acc.inputTargets.push_back(child);
        }
        collect(child, acc);
        return TRUE;
    }, reinterpret_cast<LPARAM>(&out));
}

// The main Teams window carries a distinctive class, which avoids matching a notification
// toast or a call window.
HWND find_teams_window()
{
    HWND found = nullptr;
    EnumWindows([](HWND h, LPARAM param) -> BOOL {
        if (!IsWindowVisible(h)) return TRUE;
        if (class_of(h) != L"TeamsWebView") return TRUE;
        *reinterpret_cast<HWND *>(param) = h;
        return FALSE;
    }, reinterpret_cast<LPARAM>(&found));
    return found;
}

TeamsWindows discover()
{
    TeamsWindows w;
    w.top = find_teams_window();
    if (w.top) collect(w.top, w);
    return w;
}

// Distinguishes "Teams is not running" from "Teams is running with no visible window",
// which are different health states with different repairs: only the second is
// recoverable without launching anything.
bool teams_process_running()
{
    winrt::handle snapshot{CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)};
    if (!snapshot) return false;

    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    if (!Process32FirstW(snapshot.get(), &entry)) return false;
    do {
        if (_wcsicmp(entry.szExeFile, L"ms-teams.exe") == 0) return true;
    } while (Process32NextW(snapshot.get(), &entry));
    return false;
}

// --- process-wide state --------------------------------------------------

struct State {
    TeamsWindows windows;
    std::vector<winrt::com_ptr<IAccessible>> held;  // keeps the Chromium tree alive
    winrt::com_ptr<IUIAutomation> uia;
    /// Guards everything above. The sync loop drives Teams from its own thread while the
    /// tray's UI thread reads health for the menu, and `tw_open` clears and repopulates
    /// `held` — reading it mid-clear is a use-after-free waiting to happen.
    std::recursive_mutex mutex;
};

State &state()
{
    static State s;
    return s;
}

/// COM initialisation is **per thread**, not per process.
///
/// This was previously guarded by a single process-wide flag, so whichever thread happened
/// to call first initialised COM and every other thread — including the one that actually
/// drives Teams — silently never did. It appeared to work because a process with a live
/// MTA often lets an uninitialised thread through, which is exactly the kind of "works
/// until it doesn't" that shows up as an unexplained disappearance hours later.
void ensure_com()
{
    static thread_local bool done = false;
    if (done) return;
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    done = true;
}

// --- MSAA ----------------------------------------------------------------

VARIANT self_id()
{
    VARIANT v;
    VariantInit(&v);
    v.vt = VT_I4;
    v.lVal = CHILDID_SELF;
    return v;
}

std::wstring msaa_name(IAccessible *acc, VARIANT child)
{
    BSTR raw = nullptr;
    if (FAILED(acc->get_accName(child, &raw)) || raw == nullptr) return {};
    std::wstring out(raw, SysStringLen(raw));
    SysFreeString(raw);
    return out;
}

// Reading is what materialises the Chromium tree -- counting children is not enough. The
// macOS implementation found the same thing walking the WebView helper processes: asking
// for a role at every node turned a 46-second failure into a 0.3-second success.
void touch(IAccessible *acc, int depth, int maxDepth, int &budget)
{
    if (acc == nullptr || depth > maxDepth || budget <= 0) return;
    --budget;

    VARIANT self = self_id();
    BSTR name = nullptr;
    if (SUCCEEDED(acc->get_accName(self, &name)) && name) SysFreeString(name);
    VARIANT role;
    VariantInit(&role);
    acc->get_accRole(self, &role);
    VariantClear(&role);

    long count = 0;
    if (FAILED(acc->get_accChildCount(&count)) || count <= 0) return;

    std::vector<VARIANT> kids(static_cast<size_t>(count));
    long got = 0;
    if (FAILED(AccessibleChildren(acc, 0, count, kids.data(), &got))) return;

    for (long i = 0; i < got; ++i) {
        if (budget > 0 && kids[i].vt == VT_DISPATCH && kids[i].pdispVal) {
            winrt::com_ptr<IAccessible> child;
            if (SUCCEEDED(kids[i].pdispVal->QueryInterface(IID_PPV_ARGS(child.put()))))
                touch(child.get(), depth + 1, maxDepth, budget);
        }
        VariantClear(&kids[i]);
    }
}

// Depth-first search for the first node whose accessible name starts with prefix. Returns
// the owning IAccessible and the child id to act on.
bool msaa_find(IAccessible *acc, const std::wstring &prefix, int depth,
               winrt::com_ptr<IAccessible> &outAcc, VARIANT &outChild)
{
    if (acc == nullptr || depth > 40) return false;

    VARIANT self = self_id();
    if (msaa_name(acc, self).rfind(prefix, 0) == 0) {
        outAcc.copy_from(acc);
        outChild = self;
        return true;
    }

    long count = 0;
    if (FAILED(acc->get_accChildCount(&count)) || count <= 0) return false;

    std::vector<VARIANT> kids(static_cast<size_t>(count));
    long got = 0;
    if (FAILED(AccessibleChildren(acc, 0, count, kids.data(), &got))) return false;

    bool hit = false;
    for (long i = 0; i < got; ++i) {
        if (!hit && kids[i].vt == VT_DISPATCH && kids[i].pdispVal) {
            winrt::com_ptr<IAccessible> child;
            if (SUCCEEDED(kids[i].pdispVal->QueryInterface(IID_PPV_ARGS(child.put()))))
                hit = msaa_find(child.get(), prefix, depth + 1, outAcc, outChild);
        } else if (!hit && kids[i].vt == VT_I4) {
            // A leaf exposed as a child id rather than as an object.
            VARIANT id = kids[i];
            if (msaa_name(acc, id).rfind(prefix, 0) == 0) {
                outAcc.copy_from(acc);
                outChild = id;
                hit = true;
            }
        }
        if (kids[i].vt != VT_I4) VariantClear(&kids[i]);
    }
    return hit;
}

// --- string marshalling --------------------------------------------------

void copy_out(uint16_t *dst, size_t cap, const std::wstring &src)
{
    const size_t n = (std::min)(src.size(), cap - 1);
    std::copy_n(reinterpret_cast<const uint16_t *>(src.data()), n, dst);
    dst[n] = 0;
}

std::wstring cached_string(IUIAutomationElement *e, PROPERTYID id)
{
    VARIANT v;
    VariantInit(&v);
    if (FAILED(e->GetCachedPropertyValue(id, &v))) return {};
    std::wstring out;
    if (v.vt == VT_BSTR && v.bstrVal) out.assign(v.bstrVal, SysStringLen(v.bstrVal));
    VariantClear(&v);
    return out;
}

int32_t cached_int(IUIAutomationElement *e, PROPERTYID id)
{
    VARIANT v;
    VariantInit(&v);
    if (FAILED(e->GetCachedPropertyValue(id, &v))) return 0;
    int32_t out = (v.vt == VT_I4) ? v.lVal : 0;
    VariantClear(&v);
    return out;
}

// --- key delivery --------------------------------------------------------

// Two details are load-bearing. The message goes to the Chrome_WidgetWin_1 browser widget,
// not to the Chrome_RenderWidgetHostHWND that carries accessibility. And lParam must hold
// the real scan code: Chromium reads it, and silently discards a key posted with a zero
// lParam -- which looks exactly like the key having been ignored.
void send_key(int virtualKey)
{
    auto &s = state();
    const UINT scan = MapVirtualKeyW(static_cast<UINT>(virtualKey), MAPVK_VK_TO_VSC);
    const LPARAM down = static_cast<LPARAM>(1 | (scan << 16));
    const LPARAM up = static_cast<LPARAM>(1 | (scan << 16) | 0xC0000000);

    for (HWND h : s.windows.inputTargets) {
        PostMessageW(h, WM_KEYDOWN, static_cast<WPARAM>(virtualKey), down);
        PostMessageW(h, WM_KEYUP, static_cast<WPARAM>(virtualKey), up);
    }
}

} // namespace

// --- public surface ------------------------------------------------------

extern "C" int32_t tw_open(void)
{
    std::lock_guard<std::recursive_mutex> guard(state().mutex);
    ensure_com();
    auto &s = state();

    s.windows = discover();
    if (s.windows.top == nullptr) return TW_ERR_NO_TEAMS;

    s.held.clear();
    for (HWND rw : s.windows.renderWidgets) {
        DWORD_PTR unused = 0;
        SendMessageTimeoutW(rw, WM_GETOBJECT, 0, OBJID_CLIENT, SMTO_ABORTIFHUNG, 1000, &unused);

        winrt::com_ptr<IAccessible> acc;
        if (FAILED(AccessibleObjectFromWindow(rw, OBJID_CLIENT, IID_IAccessible,
                                              reinterpret_cast<void **>(acc.put()))))
            continue;
        if (!acc) continue;

        int budget = 4000;
        touch(acc.get(), 0, 6, budget);
        s.held.push_back(acc);
    }
    if (s.held.empty()) return TW_ERR_TREE_UNAVAIL;

    if (!s.uia) {
        if (FAILED(CoCreateInstance(CLSID_CUIAutomation8, nullptr, CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(s.uia.put()))))
            return TW_ERR_COM;
    }
    return TW_OK;
}

extern "C" void tw_close(void)
{
    std::lock_guard<std::recursive_mutex> guard(state().mutex);
    auto &s = state();
    s.held.clear();
    s.uia = nullptr;
}

extern "C" int32_t tw_health(void)
{
    std::lock_guard<std::recursive_mutex> guard(state().mutex);
    HWND top = find_teams_window();
    if (top == nullptr) {
        // No visible TeamsWebView window. Distinguish "Teams is not running at all" from
        // "Teams is running with its window closed to the tray", because only the second
        // is recoverable without launching anything.
        return teams_process_running() ? TW_HEALTH_NO_WINDOW : TW_HEALTH_NOT_RUNNING;
    }
    if (IsIconic(top)) return TW_HEALTH_MINIMIZED;

    auto &s = state();
    if (s.held.empty() || !s.uia) return TW_HEALTH_TREE_UNAVAIL;
    return TW_HEALTH_OK;
}

extern "C" int32_t tw_window_restore(void)
{
    HWND top = find_teams_window();
    if (top == nullptr) return TW_ERR_NO_TEAMS;

    // SW_SHOWNOACTIVATE, never SW_RESTORE: the latter activates, and activation is the one
    // thing this product must never do.
    ShowWindow(top, SW_SHOWNOACTIVATE);

    // Ordering the window in without activating it. A minimised Chromium window is treated
    // as occluded and discards interactions even once the tree reads healthy again, which
    // is why this is not merely cosmetic.
    SetWindowPos(top, HWND_TOP, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    return TW_OK;
}

extern "C" int32_t tw_window_minimize(void)
{
    HWND top = find_teams_window();
    if (top == nullptr) return TW_ERR_NO_TEAMS;
    ShowWindow(top, SW_MINIMIZE);
    return TW_OK;
}

extern "C" int32_t tw_teams_version(uint16_t *out, int32_t capacity)
{
    if (out == nullptr || capacity <= 0) return TW_ERR_COM;
    out[0] = 0;

    HWND top = find_teams_window();
    if (top == nullptr) return TW_ERR_NO_TEAMS;

    DWORD pid = 0;
    GetWindowThreadProcessId(top, &pid);
    if (pid == 0) return TW_ERR_NO_TEAMS;

    winrt::handle process{OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)};
    if (!process) return TW_ERR_NO_TEAMS;

    wchar_t path[MAX_PATH] = {};
    DWORD size = MAX_PATH;
    if (!QueryFullProcessImageNameW(process.get(), 0, path, &size)) return TW_ERR_NO_TEAMS;

    DWORD unused = 0;
    const DWORD infoSize = GetFileVersionInfoSizeW(path, &unused);
    if (infoSize == 0) return TW_ERR_NOT_FOUND;

    std::vector<uint8_t> buffer(infoSize);
    if (!GetFileVersionInfoW(path, 0, infoSize, buffer.data())) return TW_ERR_NOT_FOUND;

    VS_FIXEDFILEINFO *fixed = nullptr;
    UINT fixedLength = 0;
    if (!VerQueryValueW(buffer.data(), L"\\", reinterpret_cast<LPVOID *>(&fixed), &fixedLength) || fixed == nullptr)
        return TW_ERR_NOT_FOUND;

    wchar_t rendered[64] = {};
    swprintf(rendered, 64, L"%u.%u.%u.%u",
             HIWORD(fixed->dwFileVersionMS), LOWORD(fixed->dwFileVersionMS),
             HIWORD(fixed->dwFileVersionLS), LOWORD(fixed->dwFileVersionLS));
    copy_out(out, static_cast<size_t>(capacity), rendered);
    return TW_OK;
}

namespace {

struct TitleScan {
    std::wstring joined;
    std::vector<DWORD> pids;
};

} // namespace

extern "C" int32_t tw_teams_window_titles(uint16_t *out, int32_t capacity)
{
    if (out == nullptr || capacity <= 0) return TW_ERR_COM;
    out[0] = 0;

    TitleScan scan;
    {
        winrt::handle snapshot{CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)};
        if (!snapshot) return TW_ERR_NO_TEAMS;
        PROCESSENTRY32W entry{};
        entry.dwSize = sizeof(entry);
        if (Process32FirstW(snapshot.get(), &entry)) {
            do {
                if (_wcsicmp(entry.szExeFile, L"ms-teams.exe") == 0)
                    scan.pids.push_back(entry.th32ProcessID);
            } while (Process32NextW(snapshot.get(), &entry));
        }
    }
    if (scan.pids.empty()) return TW_ERR_NO_TEAMS;

    EnumWindows([](HWND h, LPARAM param) -> BOOL {
        auto &s = *reinterpret_cast<TitleScan *>(param);
        if (!IsWindowVisible(h)) return TRUE;

        DWORD pid = 0;
        GetWindowThreadProcessId(h, &pid);
        if (std::find(s.pids.begin(), s.pids.end(), pid) == s.pids.end()) return TRUE;

        wchar_t title[512] = {};
        if (GetWindowTextW(h, title, 512) <= 0) return TRUE;
        if (!s.joined.empty()) s.joined += L"\n";
        s.joined += title;
        return TRUE;
    }, reinterpret_cast<LPARAM>(&scan));

    copy_out(out, static_cast<size_t>(capacity), scan.joined);
    return TW_OK;
}

extern "C" int32_t tw_teams_is_frontmost(void)
{
    HWND fore = GetForegroundWindow();
    if (fore == nullptr) return 0;

    DWORD forePid = 0;
    GetWindowThreadProcessId(fore, &forePid);
    if (forePid == 0) return 0;

    winrt::handle process{OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, forePid)};
    if (!process) return 0;

    wchar_t path[MAX_PATH] = {};
    DWORD size = MAX_PATH;
    if (!QueryFullProcessImageNameW(process.get(), 0, path, &size)) return 0;

    // Compare the executable rather than the window title: Teams titles are page-authored
    // and a chat named "Microsoft Teams" would otherwise read as Teams being frontmost.
    const wchar_t *leaf = wcsrchr(path, L'\\');
    leaf = leaf ? leaf + 1 : path;
    return _wcsicmp(leaf, L"ms-teams.exe") == 0 ? 1 : 0;
}

extern "C" int32_t tw_foreground_title(uint16_t *out, int32_t capacity)
{
    if (out == nullptr || capacity <= 0) return TW_ERR_COM;
    out[0] = 0;

    HWND fore = GetForegroundWindow();
    if (fore == nullptr) return TW_ERR_NOT_FOUND;

    wchar_t title[512] = {};
    GetWindowTextW(fore, title, 512);
    copy_out(out, static_cast<size_t>(capacity), title);
    return TW_OK;
}

extern "C" int32_t tw_park_focus(void)
{
    HWND console = GetConsoleWindow();
    if (console == nullptr) return TW_ERR_NOT_FOUND;

    // SetForegroundWindow is refused for a process that is not already foreground, unless
    // its input queue is attached to the current foreground thread first.
    HWND fore = GetForegroundWindow();
    const DWORD foreThread = GetWindowThreadProcessId(fore, nullptr);
    const DWORD self = GetCurrentThreadId();

    AttachThreadInput(self, foreThread, TRUE);
    ShowWindow(console, SW_SHOWNORMAL);
    const BOOL ok = SetForegroundWindow(console);
    AttachThreadInput(self, foreThread, FALSE);

    return ok ? TW_OK : TW_ERR_NOT_FOUND;
}

extern "C" int32_t tw_snapshot(TWNode *out, int32_t capacity, int32_t *count)
{
    std::lock_guard<std::recursive_mutex> guard(state().mutex);
    if (out == nullptr || count == nullptr || capacity <= 0) return TW_ERR_COM;
    *count = 0;

    auto &s = state();
    if (!s.uia || s.windows.top == nullptr) return TW_ERR_TREE_UNAVAIL;

    winrt::com_ptr<IUIAutomationElement> root;
    if (FAILED(s.uia->ElementFromHandle(s.windows.top, root.put())) || !root)
        return TW_ERR_NO_TEAMS;

    // Only the control types a selector can match. The full Teams tree is ~4300 nodes,
    // most of it chat content in Groups and Panes; filtering server-side keeps this to a
    // few hundred rows and one cross-process call.
    static const int kTypes[] = {
        UIA_ButtonControlTypeId, UIA_CheckBoxControlTypeId, UIA_ComboBoxControlTypeId,
        UIA_EditControlTypeId, UIA_MenuItemControlTypeId, UIA_TextControlTypeId,
        UIA_WindowControlTypeId,
    };

    winrt::com_ptr<IUIAutomationCondition> condition;
    for (int type : kTypes) {
        VARIANT v;
        VariantInit(&v);
        v.vt = VT_I4;
        v.lVal = type;
        winrt::com_ptr<IUIAutomationCondition> one;
        if (FAILED(s.uia->CreatePropertyCondition(UIA_ControlTypePropertyId, v, one.put()))) continue;
        if (!condition) {
            condition = one;
        } else {
            winrt::com_ptr<IUIAutomationCondition> combined;
            if (SUCCEEDED(s.uia->CreateOrCondition(condition.get(), one.get(), combined.put())))
                condition = combined;
        }
    }
    if (!condition) return TW_ERR_COM;

    winrt::com_ptr<IUIAutomationCacheRequest> cache;
    if (FAILED(s.uia->CreateCacheRequest(cache.put()))) return TW_ERR_COM;
    cache->AddProperty(UIA_NamePropertyId);
    cache->AddProperty(UIA_AutomationIdPropertyId);
    cache->AddProperty(UIA_ControlTypePropertyId);
    cache->AddProperty(UIA_HelpTextPropertyId);
    cache->AddProperty(UIA_ValueValuePropertyId);

    winrt::com_ptr<IUIAutomationElementArray> found;
    if (FAILED(root->FindAllBuildCache(TreeScope_Descendants, condition.get(), cache.get(), found.put())) || !found)
        return TW_ERR_COM;

    int length = 0;
    found->get_Length(&length);

    int written = 0;
    for (int i = 0; i < length && written < capacity; ++i) {
        winrt::com_ptr<IUIAutomationElement> e;
        if (FAILED(found->GetElement(i, e.put())) || !e) continue;

        TWNode &n = out[written];
        n.controlType = cached_int(e.get(), UIA_ControlTypePropertyId);
        n.isDialog = (n.controlType == UIA_WindowControlTypeId) ? 1 : 0;
        copy_out(n.name, TW_NAME_MAX, cached_string(e.get(), UIA_NamePropertyId));
        copy_out(n.automationId, TW_ID_MAX, cached_string(e.get(), UIA_AutomationIdPropertyId));
        copy_out(n.value, TW_NAME_MAX, cached_string(e.get(), UIA_ValueValuePropertyId));
        copy_out(n.helpText, TW_ID_MAX, cached_string(e.get(), UIA_HelpTextPropertyId));
        ++written;
    }
    *count = written;
    return TW_OK;
}

extern "C" int32_t tw_msaa_press(const uint16_t *namePrefix)
{
    std::lock_guard<std::recursive_mutex> guard(state().mutex);
    if (namePrefix == nullptr) return TW_ERR_COM;
    auto &s = state();
    if (s.held.empty()) return TW_ERR_TREE_UNAVAIL;

    const std::wstring prefix(reinterpret_cast<const wchar_t *>(namePrefix));

    for (auto &doc : s.held) {
        winrt::com_ptr<IAccessible> target;
        VARIANT child;
        VariantInit(&child);
        if (!msaa_find(doc.get(), prefix, 0, target, child)) continue;
        if (!target) continue;
        // Delivered, not confirmed. The caller observes the state change.
        target->accDoDefaultAction(child);
        return TW_OK;
    }
    return TW_ERR_NOT_FOUND;
}

extern "C" int32_t tw_msaa_focus(const uint16_t *namePrefix)
{
    std::lock_guard<std::recursive_mutex> guard(state().mutex);
    if (namePrefix == nullptr) return TW_ERR_COM;
    auto &s = state();
    if (s.held.empty()) return TW_ERR_TREE_UNAVAIL;

    const std::wstring prefix(reinterpret_cast<const wchar_t *>(namePrefix));

    for (auto &doc : s.held) {
        winrt::com_ptr<IAccessible> target;
        VARIANT child;
        VariantInit(&child);
        if (!msaa_find(doc.get(), prefix, 0, target, child)) continue;
        if (!target) continue;
        // SELFLAG_TAKEFOCUS. Measured not to disturb the foreground window, unlike UI
        // Automation's SetFocus.
        target->accSelect(SELFLAG_TAKEFOCUS, child);
        return TW_OK;
    }
    return TW_ERR_NOT_FOUND;
}

extern "C" int32_t tw_set_value(const uint16_t *automationId, const uint16_t *text)
{
    std::lock_guard<std::recursive_mutex> guard(state().mutex);
    if (automationId == nullptr || text == nullptr) return TW_ERR_COM;
    auto &s = state();
    if (!s.uia || s.windows.top == nullptr) return TW_ERR_TREE_UNAVAIL;

    winrt::com_ptr<IUIAutomationElement> root;
    if (FAILED(s.uia->ElementFromHandle(s.windows.top, root.put())) || !root)
        return TW_ERR_NO_TEAMS;

    VARIANT idValue;
    VariantInit(&idValue);
    idValue.vt = VT_BSTR;
    idValue.bstrVal = SysAllocString(reinterpret_cast<const wchar_t *>(automationId));

    winrt::com_ptr<IUIAutomationCondition> condition;
    HRESULT hr = s.uia->CreatePropertyCondition(UIA_AutomationIdPropertyId, idValue, condition.put());
    VariantClear(&idValue);
    if (FAILED(hr) || !condition) return TW_ERR_COM;

    winrt::com_ptr<IUIAutomationElement> element;
    if (FAILED(root->FindFirst(TreeScope_Descendants, condition.get(), element.put())) || !element)
        return TW_ERR_NOT_FOUND;

    winrt::com_ptr<IUIAutomationValuePattern> value;
    if (FAILED(element->GetCurrentPatternAs(UIA_ValuePatternId, IID_PPV_ARGS(value.put()))) || !value)
        return TW_ERR_NOT_FOUND;

    BSTR payload = SysAllocString(reinterpret_cast<const wchar_t *>(text));
    hr = value->SetValue(payload);
    SysFreeString(payload);

    // Delivered, not confirmed: Chromium accepts SetValue on a contenteditable and may
    // leave the editor's own model untouched. The caller reads the value back.
    return SUCCEEDED(hr) ? TW_OK : TW_ERR_COM;
}

extern "C" int32_t tw_type_text(const uint16_t *text)
{
    std::lock_guard<std::recursive_mutex> guard(state().mutex);
    if (text == nullptr) return TW_ERR_COM;
    auto &s = state();
    if (s.windows.inputTargets.empty()) return TW_ERR_NO_TEAMS;

    for (const uint16_t *p = text; *p != 0; ++p) {
        for (HWND h : s.windows.inputTargets)
            PostMessageW(h, WM_CHAR, static_cast<WPARAM>(*p), 1);
    }
    return TW_OK;
}

extern "C" int32_t tw_clear_field(int32_t count)
{
    std::lock_guard<std::recursive_mutex> guard(state().mutex);
    auto &s = state();
    if (s.windows.inputTargets.empty()) return TW_ERR_NO_TEAMS;
    if (count < 0) return TW_ERR_COM;

    // A posted Ctrl+A does not select: Chromium reads modifier state from the receiving
    // thread's keyboard, which PostMessage does not touch, so the "a" arrives as a literal
    // character and corrupts the field. Backspace carries no modifier and does work.
    send_key(VK_END);
    for (int32_t i = 0; i < count; ++i) send_key(VK_BACK);
    return TW_OK;
}

extern "C" int32_t tw_post_key(int32_t virtualKey)
{
    std::lock_guard<std::recursive_mutex> guard(state().mutex);
    if (state().windows.inputTargets.empty()) return TW_ERR_NO_TEAMS;
    send_key(virtualKey);
    return TW_OK;
}
