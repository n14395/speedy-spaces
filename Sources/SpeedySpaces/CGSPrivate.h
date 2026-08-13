// Bridging header exposing private window-server calls to Swift.
//
// The underlying symbols (CGSMainConnectionID, CGSCopyManagedDisplaySpaces) live in
// /System/Library/PrivateFrameworks/SkyLight.framework, which on modern macOS ships
// only inside the dyld shared cache (no on-disk stub to link against). We therefore
// resolve them at runtime with dlsym (see CGSShim.c) instead of link-time linking,
// which is also more robust to per-OS symbol drift.
#ifndef CGSPRIVATE_H
#define CGSPRIVATE_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

typedef int CGSConnectionID;

// NOTE: CGDisplayCreateUUIDFromDisplayID (used to match an NSScreen to its Space's
// "Display Identifier") is a public ColorSync symbol already visible to Swift via the
// SDK, so it is not re-declared here.

/// Default window-server connection for this process (0 if unavailable).
CGSConnectionID sm_mainConnectionID(void);

/// Snapshot of displays and their Spaces. Returns a +1 retained CFArray (Swift
/// manages the release), or NULL if the symbol can't be resolved on this OS.
CFArrayRef sm_copyManagedDisplaySpaces(CGSConnectionID cid) CF_RETURNS_RETAINED;

/// Allow CGDisplayHideCursor to hide the pointer from a background (accessory) app — needed so
/// the invisible window-move grab can hide the cursor while it drives the synthetic drag.
void sm_setsCursorInBackground(void);

#include <stdbool.h>

// --- Mission Control engine (Hammerspoon technique) -----------------------
// Toggle Mission Control etc. via the private Dock notification (e.g. "com.apple.expose.awake").
bool sm_coreDockSendNotification(CFStringRef name);
bool sm_missionControlSymbolsAvailable(void);

// --- Window/space membership + AX window ids ------------------------------
#include <ApplicationServices/ApplicationServices.h>
// Space ids containing this window (+1 retained CFArray of CFNumber), or NULL. Used to
// VERIFY moves — the underlying move calls return void and can silently no-op.
CFArrayRef sm_copySpaceIDsForWindow(uint32_t wid) CF_RETURNS_RETAINED;
// Window ID for an AXUIElement of role AXWindow (private _AXUIElementGetWindow).
bool sm_windowIDForAXElement(AXUIElementRef element, uint32_t *outWID);
bool sm_axWindowIDSymbolAvailable(void);

// --- Switcher HUD sticky space --------------------------------------------
// A window whose ONLY space is a private, always-shown, unmanaged space is composited
// outside the managed-space viewport: it holds still during the space-switch slide
// instead of riding out with the outgoing space (the system-bezel technique).
// Create + show such a space at the given absolute level; 0 on failure.
uint64_t sm_stickySpaceCreate(int level);
bool sm_stickySpaceSymbolsAvailable(void);
// Atomically add the window to the space AND remove it from all others (0x7 mask).
bool sm_stickySpaceAttachWindow(uint32_t wid, uint64_t spaceID);

// --- Space reordering (drag-to-relocate HUD tiles) ------------------------
// The Dock's own Mission Control tile-drag commit: move a managed space to a
// position (display, index). Same call covers in-display reorder (same UUID,
// new index) and cross-display moves (different UUID). Returns the raw CGError
// (0 = success) or -1 if the symbol can't be resolved on this OS.
int32_t sm_moveManagedSpaceToDisplayIndex(uint64_t spaceID, CFStringRef displayUUID, uint32_t index);
bool sm_spaceReorderSymbolAvailable(void);
// The Dock's persistence write (CGSPersistenceSaveSpaceConfiguration): asks the
// window server to save the current space arrangement so it survives login.
// Returns the raw CGError, or -1 if unresolvable.
int32_t sm_persistenceSaveSpaceConfiguration(void);
bool sm_persistenceSymbolAvailable(void);

// --- Symbolic hotkeys (macOS's own keyboard shortcuts) --------------------
// Live window-server symbolic-hotkey table (CGS[Set|Is]SymbolicHotKeyEnabled /
// CGS[Set|Get]SymbolicHotKeyValue). Changes here take effect immediately but do NOT
// persist across login — pair with a com.apple.symbolichotkeys plist write (the plist
// alone only applies at next login). Returns false if a symbol can't be resolved.
bool sm_symbolicHotKeySetEnabled(int hotKey, bool enabled);
bool sm_symbolicHotKeyIsEnabled(int hotKey);
bool sm_symbolicHotKeySetValue(int hotKey, uint16_t keyChar, uint16_t keyCode, uint32_t modifiers);

// --- Mission Control overlay fast geometry path ---------------------------
#include <CoreGraphics/CGGeometry.h>
// Bounds of one window in global CG (top-left-origin) coords — same frame as
// kCGWindowBounds, but a single cheap window-server call (SLSGetWindowBounds)
// instead of a full CGWindowList snapshot. False if the symbol is unavailable
// OR the window is gone; use sm_getWindowBoundsAvailable to tell those apart.
bool sm_getWindowBounds(uint32_t wid, CGRect *outBounds);
bool sm_getWindowBoundsAvailable(void);

#endif /* CGSPRIVATE_H */
