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

#include <winrt/base.h>

#include <algorithm>
#include <string>
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

// --- process-wide state --------------------------------------------------

struct State {
    TeamsWindows windows;
    std::vector<winrt::com_ptr<IAccessible>> held;  // keeps the Chromium tree alive
    winrt::com_ptr<IUIAutomation> uia;
    bool comReady = false;
};

State &state()
{
    static State s;
    return s;
}

void ensure_com()
{
    auto &s = state();
    if (s.comReady) return;
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    s.comReady = true;
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

} // namespace

// --- public surface ------------------------------------------------------

extern "C" int32_t tw_open(void)
{
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
    auto &s = state();
    s.held.clear();
    s.uia = nullptr;
}

extern "C" int32_t tw_snapshot(TWNode *out, int32_t capacity, int32_t *count)
{
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

extern "C" int32_t tw_post_key(int32_t virtualKey)
{
    auto &s = state();
    if (s.windows.inputTargets.empty()) return TW_ERR_NO_TEAMS;

    const UINT scan = MapVirtualKeyW(static_cast<UINT>(virtualKey), MAPVK_VK_TO_VSC);
    const LPARAM down = static_cast<LPARAM>(1 | (scan << 16));
    const LPARAM up = static_cast<LPARAM>(1 | (scan << 16) | 0xC0000000);

    for (HWND h : s.windows.inputTargets) {
        PostMessageW(h, WM_KEYDOWN, static_cast<WPARAM>(virtualKey), down);
        PostMessageW(h, WM_KEYUP, static_cast<WPARAM>(virtualKey), up);
    }
    return TW_OK;
}
