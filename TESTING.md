# Testing SpeedySpaces

Two layers: an **automated suite** (`tests/test.sh`) covering everything a machine can
verify on this host, and a **manual checklist** for what it can't (physical keyboard,
trackpad gestures, visual feel).

## Automated suite

```
tests/test.sh              # all tiers (unit + ro + live + destructive)
tests/test.sh unit         # --selftest only (pure logic, ~285 checks, safe anywhere)
tests/test.sh ro           # read-only integration (standalone CLI flags)
tests/test.sh live         # drives the running app; switches spaces and restores
tests/test.sh destructive  # reorder / add-remove desktop probes (self-restoring)
```

Exit code = number of failed checks. Output is `PASS [tier] name` / `FAIL [tier] name — detail`
plus a `TOTAL:` line.

### Tiers

| Tier | Touches | Safety |
|---|---|---|
| `unit` | nothing — in-process pure logic via `--selftest` | always safe |
| `ro` | window server reads (`--dump`, `--symbols`, …), config export to a temp file | always safe |
| `live` | the running app via its distributed-notification side doors; visibly switches spaces, flashes the switcher HUD | snapshots the current space per display first and restores it (also on Ctrl-C via a trap); saves/restores the `hotkeyDebugLog` and `hotkeyWrapAround` defaults |
| `destructive` | desktop order (reorder probe, `--set-space-order`), desktop count (add/remove via the Mission Control choreography) | 3-second Ctrl-C banner; every probe restores its own changes and the runner double-checks with `--dump` diffs; on failure it prints recovery guidance |

### How the live tier works (and its assumptions)

- Synthetic **keyboard** events are dropped system-wide on this machine, so shortcut
  dispatch is tested through `--fire-hotkey <actionId>` (the `com.n14395.SpeedySpaces.debug.hotkey`
  side door) instead of real key presses.
- Directional commands act on the display **under the pointer**; the runner parks the
  pointer at (100, 100) on the primary display before every directional action. Moving
  the mouse while the live tier runs can still race a test — keep hands off for ~2 min.
- State assertions poll `--dump` (the `*CURRENT*` marker per display); log assertions
  read byte-offset tails of `/tmp/speedyspaces-hotkey-diag.log` (the runner enables
  `hotkeyDebugLog` for the duration).
- The runner relaunches the app if it isn't running, and tolerates a concurrent
  rebuild replacing it mid-run (each test re-checks and retries once). Parallel
  Claude/dev sessions that pkill or drive the app **will** cause spurious failures —
  rerun the tier in a quiet window before believing a red result.

### What is deliberately NOT automated (and why)

- **Real shortcut presses / chords** — synthetic keyboard is dead on this host.
- **Screen-capture visual assertions** — the ad-hoc signing loses the Screen Recording
  grant on every rebuild; captures are eyeball-only.
- **Animation feel** (switch slide, HUD reflow, MC overlay springs) — inherently visual;
  the underlying math is pinned in `--selftest` instead.
- **Trackpad gestures, Shortcuts.app discovery, login item, Settings interactions** —
  hardware/OS-UI dependent.

## Manual checklist

Run after significant changes. Each item: do the steps, tick if the expectation holds.

### Keyboard (physical presses required)

- [ ] **Next/Previous Space hotkeys** (app's own, if bound): press once mid-row → moves
      one space with the slide animation.
- [ ] **Rapid-press accumulation**: from ~Desktop 8, press next 4–5× quickly → lands
      4–5 spaces on, counting every press (no waiting for animations).
- [ ] **Wrap-around (app hotkeys)**: with the Settings toggle ON, next from the last
      desktop → first; previous from the first → last. With it OFF → stops at the ends.
- [ ] **Wrap-around (system ⌃-arrows)**: same four cases using the macOS Move left/right
      a space shortcuts — behavior must match the app's own hotkeys, including rapid-press
      accumulation across the wrap (8→9→10→1→2 without pauses).
- [ ] **Remapped system shortcuts**: change "Move left a space" to a non-default chord in
      System Settings ▸ Keyboard ▸ Shortcuts → the wrap interception follows the new
      chord within ~1 min (or after relaunch); the old chord does nothing special.
- [ ] **Hold-to-show switcher chord**: press and hold → HUD appears; arrow keys move the
      selection; release → switches to the selected space; tap (quick press-release) →
      HUD flashes and hides without switching.
- [ ] **Per-space shortcuts + Switch to Space N**: bound chords land on the right space;
      Move Window variants carry the focused window (and Follow variants follow it).
- [ ] **Menu jump field**: right-click the menubar strip, type a space name → list
      filters (exact > prefix > substring, named spaces first); ⏎ jumps; arrows move the
      selection.

### Trackpad / mouse

- [ ] **Three-finger swipe** between spaces still works normally with the app running
      (the event tap must not eat real gestures).
- [ ] **Switcher HUD drag-reorder**: drag a tile to a new slot → tiles reflow live, drop
      settles in place with no replay animation; native Mission Control shows the same
      order afterward. Cross-display drag moves the space to the other display.
- [ ] **Strip clicks**: left-click a square → switch; left-click the current square /
      right-click anywhere → menu; hover → tooltip with name/icon.

### Visual / animations

- [ ] **Mission Control overlay**: open MC → custom names/icons ride the thumbnails,
      track the bar expanding, and survive a native tile drag (labels stay pinned to
      their spaces). Close → overlay vanishes cleanly.
- [ ] **Switch flash**: switching spaces flashes the HUD briefly (if enabled); no stuck
      panels afterward.
- [ ] **HUD styles**: both Mission Control style and popover style render correctly on
      every display; wallpaper thumbnails appear (needs Screen Recording granted to the
      current build).

### System integration

- [ ] **Login item toggle** in Settings actually registers/unregisters (check System
      Settings ▸ General ▸ Login Items).
- [ ] **Shortcuts.app**: the SpeedySpaces actions appear and run (Switch to Space, etc.).
- [ ] **`speedyspaces://` URLs**: `open "speedyspaces://switch?index=2"` switches; malformed
      URLs are ignored quietly.
- [ ] **Settings window**: every pane opens; toggles persist across relaunch; conflict
      warnings appear when recording a chord that collides with a macOS shortcut.
- [ ] **Display topology changes**: plug/unplug a display → strip and HUD update; no
      stale panels or wrong-display switches afterward.

## Extending the suite

- Pure logic → add a `selfChecks(_:)` to the type (keep `private` helpers reachable by
  putting the checks inside the type) and register it in `SelfTest.run()`.
  Style: `check(<condition>, "<group>: <what>")`.
- App behavior with an observable side effect → add a check to the matching tier in
  `tests/test.sh`; follow the snapshot → act → poll `--dump` → restore pattern, and
  keep every mutation restored even on failure paths.
- New CLI side doors belong in `main.swift` next to the existing flags; prefer reusing
  `--dump` polling over adding new query doors.
