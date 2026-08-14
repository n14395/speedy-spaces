#include "CGSPrivate.h"
#include <dlfcn.h>
#include <string.h>

// SkyLight is already loaded into the process by AppKit at runtime, so its exported
// CGS* symbols are reachable via RTLD_DEFAULT without an explicit dlopen.

typedef CGSConnectionID (*MainConnFn)(void);
typedef CFArrayRef (*CopySpacesFn)(CGSConnectionID);

CGSConnectionID sm_mainConnectionID(void) {
    static MainConnFn fn = NULL;
    if (fn == NULL) {
        fn = (MainConnFn)dlsym(RTLD_DEFAULT, "CGSMainConnectionID");
    }
    return fn ? fn() : 0;
}

CFArrayRef sm_copyManagedDisplaySpaces(CGSConnectionID cid) {
    static CopySpacesFn fn = NULL;
    if (fn == NULL) {
        fn = (CopySpacesFn)dlsym(RTLD_DEFAULT, "CGSCopyManagedDisplaySpaces");
    }
    return fn ? fn(cid) : NULL;
}

// Let CGDisplayHideCursor work from a background (accessory) app. Without this connection
// property the hide is a no-op unless we're the foreground app; setting it lets our invisible
// window-move grab hide the pointer while it drives the synthetic title-bar drag. Undocumented
// but long-standing (CGSSetConnectionProperty + the "SetsCursorInBackground" key).
typedef CGError (*SetConnPropFn)(CGSConnectionID, CGSConnectionID, CFStringRef, CFTypeRef);
void sm_setsCursorInBackground(void) {
    static SetConnPropFn fn = NULL; static int resolved = 0;
    if (!resolved) { fn = (SetConnPropFn)dlsym(RTLD_DEFAULT, "CGSSetConnectionProperty"); resolved = 1; }
    if (!fn) return;
    CGSConnectionID cid = sm_mainConnectionID();
    fn(cid, cid, CFSTR("SetsCursorInBackground"), kCFBooleanTrue);
}

typedef CGError (*GetWindowBoundsFn)(CGSConnectionID, uint32_t, CGRect *);

static GetWindowBoundsFn sm_resolveGetWindowBounds(void) {
    static GetWindowBoundsFn fn = NULL; static int resolved = 0;
    if (!resolved) { fn = (GetWindowBoundsFn)dlsym(RTLD_DEFAULT, "SLSGetWindowBounds"); resolved = 1; }
    return fn;
}

bool sm_getWindowBoundsAvailable(void) {
    return sm_resolveGetWindowBounds() != NULL;
}

bool sm_getWindowBounds(uint32_t wid, CGRect *outBounds) {
    GetWindowBoundsFn fn = sm_resolveGetWindowBounds();
    if (!fn) return false;
    return fn(sm_mainConnectionID(), wid, outBounds) == kCGErrorSuccess;
}

// --- Window-move verification ----------------------------------------------
// Space membership of one window (CFArray of CFNumber space ids), mask 0x7 = all space
// kinds. Used to VERIFY moves — the move calls return void and can silently no-op.
typedef CFArrayRef (*CopySpacesForWindowsFn)(CGSConnectionID, uint32_t, CFArrayRef);

CFArrayRef sm_copySpaceIDsForWindow(uint32_t wid) {
    static CopySpacesForWindowsFn fn = NULL; static int resolved = 0;
    if (!resolved) {
        fn = (CopySpacesForWindowsFn)dlsym(RTLD_DEFAULT, "CGSCopySpacesForWindows");
        if (!fn) fn = (CopySpacesForWindowsFn)dlsym(RTLD_DEFAULT, "SLSCopySpacesForWindows");
        resolved = 1;
    }
    if (!fn) return NULL;
    int64_t w = wid;
    CFNumberRef num = CFNumberCreate(NULL, kCFNumberSInt64Type, &w);
    CFArrayRef windows = CFArrayCreate(NULL, (const void **)&num, 1, &kCFTypeArrayCallBacks);
    CFArrayRef spaces = fn(sm_mainConnectionID(), 0x7, windows);
    CFRelease(windows); CFRelease(num);
    return spaces;
}

// --- Switcher HUD sticky space ---------------------------------------------
// A window that lives ONLY in a private, always-shown, unmanaged space is composited
// outside the managed-space viewport, so it holds still while a space-switch slide
// animates beneath it (the technique system bezels and overlay apps use). The managed
// spaces animate; ours doesn't participate.

typedef uint64_t (*SpaceCreateFn)(CGSConnectionID, int, CFDictionaryRef);
typedef void (*SpaceLevelFn)(CGSConnectionID, uint64_t, int);
typedef void (*ShowHideSpacesFn)(CGSConnectionID, CFArrayRef);

static SpaceCreateFn sm_resolveSpaceCreate(void) {
    static SpaceCreateFn fn = NULL; static int resolved = 0;
    if (!resolved) {
        fn = (SpaceCreateFn)dlsym(RTLD_DEFAULT, "CGSSpaceCreate");
        if (!fn) fn = (SpaceCreateFn)dlsym(RTLD_DEFAULT, "SLSSpaceCreate");
        resolved = 1;
    }
    return fn;
}

bool sm_stickySpaceSymbolsAvailable(void) {
    return sm_resolveSpaceCreate() != NULL
        && (dlsym(RTLD_DEFAULT, "CGSSpaceSetAbsoluteLevel") != NULL
            || dlsym(RTLD_DEFAULT, "SLSSpaceSetAbsoluteLevel") != NULL)
        && (dlsym(RTLD_DEFAULT, "CGSShowSpaces") != NULL
            || dlsym(RTLD_DEFAULT, "SLSShowSpaces") != NULL);
}

// Create + show a sticky space at the given absolute level. Returns 0 on failure.
uint64_t sm_stickySpaceCreate(int level) {
    SpaceCreateFn create = sm_resolveSpaceCreate();
    SpaceLevelFn setLevel = (SpaceLevelFn)dlsym(RTLD_DEFAULT, "CGSSpaceSetAbsoluteLevel");
    if (!setLevel) setLevel = (SpaceLevelFn)dlsym(RTLD_DEFAULT, "SLSSpaceSetAbsoluteLevel");
    ShowHideSpacesFn show = (ShowHideSpacesFn)dlsym(RTLD_DEFAULT, "CGSShowSpaces");
    if (!show) show = (ShowHideSpacesFn)dlsym(RTLD_DEFAULT, "SLSShowSpaces");
    if (!create || !setLevel || !show) return 0;
    CGSConnectionID cid = sm_mainConnectionID();
    uint64_t sid = create(cid, 1, NULL);
    if (sid == 0) return 0;
    setLevel(cid, sid, level);
    int64_t s = (int64_t)sid;
    CFNumberRef num = CFNumberCreate(NULL, kCFNumberSInt64Type, &s);
    CFArrayRef sids = CFArrayCreate(NULL, (const void **)&num, 1, &kCFTypeArrayCallBacks);
    show(cid, sids);
    CFRelease(sids); CFRelease(num);
    return sid;
}

// Atomically add a window to the sticky space and strip its other space memberships
// (mask 0x7 = all space kinds) — SketchyBar's recipe; the separate add/remove pair
// does NOT keep the window composited on this macOS.
typedef CGError (*SpaceAttachFn)(CGSConnectionID, uint64_t, CFArrayRef, uint32_t);

bool sm_stickySpaceAttachWindow(uint32_t wid, uint64_t spaceID) {
    static SpaceAttachFn fn = NULL; static int resolved = 0;
    if (!resolved) {
        fn = (SpaceAttachFn)dlsym(RTLD_DEFAULT, "CGSSpaceAddWindowsAndRemoveFromSpaces");
        if (!fn) fn = (SpaceAttachFn)dlsym(RTLD_DEFAULT, "SLSSpaceAddWindowsAndRemoveFromSpaces");
        resolved = 1;
    }
    if (!fn) return false;
    uint32_t w = wid;
    CFNumberRef wnum = CFNumberCreate(NULL, kCFNumberSInt32Type, &w);
    CFArrayRef windows = CFArrayCreate(NULL, (const void **)&wnum, 1, &kCFTypeArrayCallBacks);
    fn(sm_mainConnectionID(), spaceID, windows, 0x7);
    CFRelease(windows); CFRelease(wnum);
    return true;
}

// --- Space reordering -------------------------------------------------------
// CGSMoveManagedSpaceToDisplayIndex is what the Dock itself imports (verified via
// dyld_info -fixups) and calls when the user drags a Mission Control tile to a new
// slot. Signature reconstructed from SkyLight's ObjC bridge operation class
// SLSBridgedMoveManagedSpaceToDisplayIndexOperation (ivars: _spaceID Q,
// _displayIdentifier NSString, _index I) and the (cid, display, space) precedent of
// CGSManagedDisplaySetCurrentSpace above. Argument order display-vs-space is the one
// residual uncertainty; the probe treats a nonzero CGError as candidate failure.
typedef int32_t (*MoveManagedSpaceFn)(CGSConnectionID, uint64_t, CFStringRef, uint32_t);

static MoveManagedSpaceFn sm_resolveMoveManagedSpace(void) {
    static MoveManagedSpaceFn fn = NULL; static int resolved = 0;
    if (!resolved) {
        fn = (MoveManagedSpaceFn)dlsym(RTLD_DEFAULT, "CGSMoveManagedSpaceToDisplayIndex");
        if (!fn) fn = (MoveManagedSpaceFn)dlsym(RTLD_DEFAULT, "SLSMoveManagedSpaceToDisplayIndex");
        resolved = 1;
    }
    return fn;
}

bool sm_spaceReorderSymbolAvailable(void) { return sm_resolveMoveManagedSpace() != NULL; }

int32_t sm_moveManagedSpaceToDisplayIndex(uint64_t spaceID, CFStringRef displayUUID, uint32_t index) {
    MoveManagedSpaceFn fn = sm_resolveMoveManagedSpace();
    if (!fn || !displayUUID) return -1;
    return fn(sm_mainConnectionID(), spaceID, displayUUID, index);
}

// The Dock also imports CGSPersistenceSaveSpaceConfiguration; most SLSPersistence*
// entry points take only the connection id.
typedef int32_t (*PersistSpacesFn)(CGSConnectionID);

static PersistSpacesFn sm_resolvePersistSpaces(void) {
    static PersistSpacesFn fn = NULL; static int resolved = 0;
    if (!resolved) {
        fn = (PersistSpacesFn)dlsym(RTLD_DEFAULT, "CGSPersistenceSaveSpaceConfiguration");
        if (!fn) fn = (PersistSpacesFn)dlsym(RTLD_DEFAULT, "SLSPersistenceSaveSpaceConfiguration");
        resolved = 1;
    }
    return fn;
}

bool sm_persistenceSymbolAvailable(void) { return sm_resolvePersistSpaces() != NULL; }

int32_t sm_persistenceSaveSpaceConfiguration(void) {
    PersistSpacesFn fn = sm_resolvePersistSpaces();
    if (!fn) return -1;
    return fn(sm_mainConnectionID());
}

typedef AXError (*AXWindowIDFn)(AXUIElementRef, uint32_t *);

static AXWindowIDFn sm_resolveAXWindowID(void) {
    static AXWindowIDFn fn = NULL; static int resolved = 0;
    if (!resolved) { fn = (AXWindowIDFn)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow"); resolved = 1; }
    return fn;
}

bool sm_axWindowIDSymbolAvailable(void) { return sm_resolveAXWindowID() != NULL; }

bool sm_windowIDForAXElement(AXUIElementRef element, uint32_t *outWID) {
    AXWindowIDFn fn = sm_resolveAXWindowID();
    if (!fn || !element || !outWID) return false;
    return fn(element, outWID) == kAXErrorSuccess;
}

typedef CGError (*CoreDockNotifyFn)(CFStringRef, int);
bool sm_coreDockSendNotification(CFStringRef name) {
    static CoreDockNotifyFn fn = NULL; static int resolved = 0;
    if (!resolved) { fn = (CoreDockNotifyFn)dlsym(RTLD_DEFAULT, "CoreDockSendNotification"); resolved = 1; }
    if (!fn) return false;
    fn(name, 0);
    return true;
}
bool sm_missionControlSymbolsAvailable(void) {
    return dlsym(RTLD_DEFAULT, "CoreDockSendNotification") != NULL;
}

// --- Symbolic hotkeys -------------------------------------------------------
typedef CGError (*SymHotSetEnabledFn)(int, bool);
typedef bool    (*SymHotIsEnabledFn)(int);
typedef CGError (*SymHotSetValueFn)(int, uint16_t, uint16_t, uint32_t);

static SymHotSetEnabledFn sm_symSetEnabled = NULL;
static SymHotIsEnabledFn  sm_symIsEnabled  = NULL;
static SymHotSetValueFn   sm_symSetValue   = NULL;
static int sm_symResolved = 0;

static void sm_resolveSymbolicHotKeySymbols(void) {
    if (sm_symResolved) return;
    sm_symSetEnabled = (SymHotSetEnabledFn)dlsym(RTLD_DEFAULT, "CGSSetSymbolicHotKeyEnabled");
    sm_symIsEnabled  = (SymHotIsEnabledFn)dlsym(RTLD_DEFAULT, "CGSIsSymbolicHotKeyEnabled");
    sm_symSetValue   = (SymHotSetValueFn)dlsym(RTLD_DEFAULT, "CGSSetSymbolicHotKeyValue");
    sm_symResolved = 1;
}

bool sm_symbolicHotKeySetEnabled(int hotKey, bool enabled) {
    sm_resolveSymbolicHotKeySymbols();
    return sm_symSetEnabled ? sm_symSetEnabled(hotKey, enabled) == 0 : false;
}

bool sm_symbolicHotKeyIsEnabled(int hotKey) {
    sm_resolveSymbolicHotKeySymbols();
    return sm_symIsEnabled ? sm_symIsEnabled(hotKey) : false;
}

bool sm_symbolicHotKeySetValue(int hotKey, uint16_t keyChar, uint16_t keyCode, uint32_t modifiers) {
    sm_resolveSymbolicHotKeySymbols();
    return sm_symSetValue ? sm_symSetValue(hotKey, keyChar, keyCode, modifiers) == 0 : false;
}

// --- SLS per-window notifications (Mission Control replay engine) -----------
// Callback signature per the community-known ABI (yabai/JankyBorders lineage),
// verified live on macOS 27.0 26A5406e via probe/mcprobe.m: the payload's first
// 4 bytes are the window id for the 8xx window events.
typedef void (*SLSConnNotifyProc)(uint32_t type, void *data, size_t len, void *ctx, int cid);
typedef CGError (*RegisterConnNotifyFn)(CGSConnectionID, SLSConnNotifyProc, uint32_t, void *);
typedef CGError (*RequestWinNotifsFn)(CGSConnectionID, uint32_t *, int);

static RegisterConnNotifyFn sm_resolveRegisterConnNotify(void) {
    static RegisterConnNotifyFn fn = NULL; static int resolved = 0;
    if (!resolved) {
        fn = (RegisterConnNotifyFn)dlsym(RTLD_DEFAULT, "SLSRegisterConnectionNotifyProc");
        resolved = 1;
    }
    return fn;
}

static RequestWinNotifsFn sm_resolveRequestWinNotifs(void) {
    static RequestWinNotifsFn fn = NULL; static int resolved = 0;
    if (!resolved) {
        fn = (RequestWinNotifsFn)dlsym(RTLD_DEFAULT, "SLSRequestNotificationsForWindows");
        resolved = 1;
    }
    return fn;
}

bool sm_slsWindowEventsAvailable(void) {
    return sm_resolveRegisterConnNotify() != NULL && sm_resolveRequestWinNotifs() != NULL;
}

static sm_slsWindowEventCallback sm_winEvtCb = NULL;

static void sm_connNotifyTrampoline(uint32_t type, void *data, size_t len, void *ctx, int cid) {
    (void)ctx; (void)cid;
    uint32_t wid = 0;
    if (data && len >= 4) memcpy(&wid, data, 4);
    sm_slsWindowEventCallback cb = sm_winEvtCb;
    if (cb) cb(type, wid);
}

bool sm_slsWindowEventsStart(sm_slsWindowEventCallback cb) {
    RegisterConnNotifyFn reg = sm_resolveRegisterConnNotify();
    if (!reg || !sm_resolveRequestWinNotifs()) return false;
    sm_winEvtCb = cb;
    static int registered = 0;
    if (registered) return true;
    // 811 create · 806 moved · 807 resized · 804 destroyed · 816 commit (observed only
    // at window teardown on this OS — an early close-confirm signal). Registration is
    // process-lifetime; delivery is gated by what sm_slsSubscribeWindowNotifications
    // asks for (811 is connection-wide once any subscription exists).
    static const uint32_t types[] = {804, 806, 807, 811, 816};
    bool ok = true;
    CGSConnectionID cid = sm_mainConnectionID();
    for (size_t i = 0; i < sizeof(types) / sizeof(types[0]); i++)
        ok = reg(cid, sm_connNotifyTrampoline, types[i], NULL) == 0 && ok;
    registered = ok;
    return ok;
}

bool sm_slsSubscribeWindowNotifications(const uint32_t *wids, int count) {
    RequestWinNotifsFn fn = sm_resolveRequestWinNotifs();
    if (!fn || !wids || count <= 0) return false;
    return fn(sm_mainConnectionID(), (uint32_t *)wids, count) == 0;
}
