// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

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
#include <CoreGraphics/CGGeometry.h>
#include <stdbool.h>
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

/// Bind the mouse button that is CURRENTLY DOWN to a server-side drag of `wid`, with the
/// grabbed point held `offset` (cursor - window origin, global CG top-left coords) from the
/// window's origin for the drag's duration. Returns the raw CGError, or -1 if the symbol is
/// unresolvable on this OS. This is how a window is "held" for the move-to-workspace walk:
/// macOS carries a dragged window across each space switch, and naming the window by ID means
/// nothing has to be clickable — the title bar may be full of toolbar controls or entirely
/// off-screen. A live button-down is mandatory; with none, the call succeeds and does nothing.
int32_t sm_dragWindowRelativeToMouse(uint32_t wid, CGPoint offset);
bool sm_dragWindowAvailable(void);

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
// Same, with an explicit CGSSpaceMask. 0x7 = managed spaces only; the unmanaged
// (sticky / transient expose) spaces need bit 3 — mission-control-labels.md found the
// expose space only under 0x8 — so 0xF sees everything.
CFArrayRef sm_copySpaceIDsForWindowMask(uint32_t wid, uint32_t mask) CF_RETURNS_RETAINED;
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

// --- SLS per-window notifications (Mission Control replay engine) ----------
// The window server pushes per-window events to a registered connection notify proc:
// 811 create, 806 moved / 807 resized (fired once per layout commit, AFTER the final
// bounds are readable — WindowManager's visible glide plays later, inside its own CA),
// 804 destroyed. Delivery rides the CGS event stream, so it only works in a process
// running a real AppKit event loop ([NSApp run]); callbacks arrive on the MAIN thread.
// Measured on macOS 27.0 26A5406e — see fix-workspace-lag.md and probe/mcprobe.m.
typedef void (*sm_slsWindowEventCallback)(uint32_t type, uint32_t wid);
bool sm_slsWindowEventsAvailable(void);
// Register `cb` for the event types above. Idempotent per process (subsequent calls
// just replace the callback). Returns false if the symbols are gone on this OS.
bool sm_slsWindowEventsStart(sm_slsWindowEventCallback cb);
// Ask for notifications about these specific windows. Stale wids are inert, so the
// full fresh list must be re-requested whenever the tracked window set changes.
bool sm_slsSubscribeWindowNotifications(const uint32_t *wids, int count);

#endif /* CGSPRIVATE_H */
