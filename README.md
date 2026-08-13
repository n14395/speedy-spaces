# SpeedySpaces

A macOS menubar app that lists your Spaces (virtual desktops) in a menu, where each
space can be **renamed** and given an **icon** (SF Symbol or emoji). The menubar shows
the **current space's icon + name**, and clicking a space **switches to it**.

## Status

Working Layer-1 core:

- ✅ Enumerates all Spaces per display via the private SkyLight/CGS window-server API
- ✅ Tracks the current space live (`NSWorkspace.activeSpaceDidChangeNotification`)
- ✅ Rename a space + assign an SF Symbol or emoji icon (persisted by space UUID)
- ✅ Menubar button shows the active space's icon + name
- ✅ Click-to-switch via Ctrl+←/→ stepping (needs Accessibility permission)
- ✅ Searchable, **categorized SF Symbol picker** (grid + search + category filter, ~230
  symbols) and system **emoji** palette
- ✅ **Open at login** (ServiceManagement) in Settings
- ✅ **Per-display menubar** — with multiple monitors, the menubar reflects the current
  space of the display you're working on (toggle in Settings)
- ✅ App icon; menubar name truncation for long names
- ✅ **Custom names in Mission Control** — while Mission Control is open, each named space's
  custom name is drawn above its thumbnail (Apple's "Desktop N" stays below it). SIP-free
  overlay, no injection; toggle in Settings. See [`FEASIBILITY.md`](FEASIBILITY.md).
- ✅ Settings window (open-at-login, per-display menubar, switch engine, Mission Control names)

## Requirements

- macOS 14+ (developed/tested on macOS 27). Uses **private frameworks**, so it cannot
  ship on the Mac App Store — distribute notarized/direct.
- Not sandboxed. For click-to-switch, grant **Accessibility** permission when prompted
  (System Settings → Privacy & Security → Accessibility). Switching uses the default
  "Move left/right a space" Mission Control shortcuts.

## Build & run

No full Xcode required — builds with the Swift toolchain / Command Line Tools:

```sh
./build.sh
open build/SpeedySpaces.app
```

Verify headlessly (no GUI):

```sh
build/SpeedySpaces.app/Contents/MacOS/SpeedySpaces --dump         # enumerate spaces
build/SpeedySpaces.app/Contents/MacOS/SpeedySpaces --symbols      # SF Symbol catalog + login-item state
```

### Open in Xcode (optional)

```sh
xcodegen generate      # produces SpeedySpaces.xcodeproj
open SpeedySpaces.xcodeproj
```

## How it works

| Concern | Mechanism |
|---------|-----------|
| List spaces / current | `CGSMainConnectionID` + `CGSCopyManagedDisplaySpaces` (resolved at runtime via `dlsym`, see `CGSShim.c`) |
| Live updates | `NSWorkspace.activeSpaceDidChangeNotification` |
| Space identity | Stable `uuid` from the window server; names/icons keyed by it |
| Persistence | JSON at `~/Library/Application Support/SpeedySpaces/spaces.json` |
| Switching | Post Ctrl+←/→ `CGEvent`s within the target's display (Accessibility) |

Private symbols are resolved defensively (`dlsym`, feature-detected) so a symbol change
in a future macOS disables a feature rather than crashing the app.

## Switching methods

Click-to-switch is implemented behind a small `SpaceSwitcher` dispatcher with four
interchangeable engines (pick one in Settings). Each is independently probeable and
self-reports PASS/FAIL + timing via a shared verifier:

- **gesture** — synthesizes a dock-swipe via the same IOHID event payload macOS's own
  three/four-finger trackpad swipe produces (macOS-27 field-4205 layout). Supports
  Instant and Natural (animated) delivery.
- **windowFocus** — fronts a window that already lives on the target space. May work
  without Accessibility permission, but can't reach a space with no windows on it
  (e.g. an empty desktop).
- **missionControl** — presses the target space's button in the Dock's Mission Control
  Accessibility surface. May be unavailable on macOS 27 if that AX surface isn't exposed.
- **keyboard** — replays the user's actual configured shortcuts (⌃N direct-jump or
  ⌃←/⌃→ stepping), i.e. what the app has always done. Needs Accessibility permission.

### Bake-off harness

Compare methods headlessly (no need to open the app) with `--dump` to find space
indices and `--probe-switch <method> <index>` to switch to one and report the result.
This needs a logged-in GUI session and, for most engines, Accessibility permission —
run it interactively, not over SSH/CI:

```bash
BIN="build/SpeedySpaces.app/Contents/MacOS/SpeedySpaces"
"$BIN" --dump
for m in gesture windowFocus missionControl keyboard; do
  echo "== $m =="; "$BIN" --probe-switch "$m" <index>; sleep 1
done
```

Also available: `--selftest` runs the pure-logic unit tests (prefs migration, gesture
step math, keyboard parsing) headlessly and prints `ALL PASS` on success.

## Layout

```
Sources/SpeedySpaces/
  CGSPrivate.h / CGSShim.c   private window-server bridge (dlsym)
  Space.swift                space model
  SpaceMetadata.swift        persisted name/icon model
  MetadataStore.swift        JSON store keyed by uuid
  SpacesManager.swift        enumeration + current + switching
  IconRendering.swift        SF Symbol / emoji -> NSImage
  StatusItemController.swift menubar item + dynamic menu
  SpaceEditorWindow.swift    rename / icon editor panel
  AppDelegate.swift / main.swift
```
