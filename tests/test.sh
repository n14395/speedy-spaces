#!/bin/bash
# SpeedySpaces tiered test suite.
#
#   tests/test.sh [unit|ro|live|destructive|all]     (no arg == all)
#
#   unit         --selftest (pure logic, ~285 checks, always safe)
#   ro           read-only integration: standalone CLI flags against the live window server
#   live         drives the RUNNING app via its side doors; switches spaces and restores
#   destructive  reorders/adds/removes desktops via the probe harnesses (self-restoring)
#
# Live/destructive tests snapshot the current space per display and restore it (also on
# Ctrl-C). Prefs touched (hotkeyDebugLog, hotkeyWrapAround) are saved and restored.
# Exit code = number of failed checks (capped at 125).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/SpeedySpaces.app"
BIN="$APP/Contents/MacOS/SpeedySpaces"
DIAG=/tmp/speedyspaces-hotkey-diag.log
DOMAIN=com.n14395.SpeedySpaces
TMP="$(mktemp -d /tmp/speedyspaces-tests.XXXXXX)"
PASS=0; FAIL=0; TIER=""; MARK=0

say() { printf '%s\n' "$*"; }
ok()  { PASS=$((PASS+1)); say "PASS [$TIER] $1"; }
bad() { FAIL=$((FAIL+1)); say "FAIL [$TIER] $1${2:+ — $2}"; }
note() { say "INFO [$TIER] $1"; }

# ---------- generic helpers ----------

dump() { "$BIN" --dump 2>/dev/null; }

# uuid of the *CURRENT* space on display $1 (index as printed by --dump)
current_uuid() {
    dump | awk -v dd="[display $1]" '
        index($0, dd) && /\*CURRENT\*/ {
            for (i = 1; i <= NF; i++) if ($i ~ /^uuid=/) { print substr($i, 6); exit }
        }'
}

# ordered uuids of display $1, from the latest snapshot
disp_uuids() {
    awk -v dd="[display $1]" '
        index($0, dd) { for (i = 1; i <= NF; i++) if ($i ~ /^uuid=/) print substr($i, 6) }
    ' "$TMP/baseline.txt"
}

snapshot() {
    dump > "$TMP/baseline.txt"
    awk '/\*CURRENT\*/ {
        u = ""; for (i = 1; i <= NF; i++) if ($i ~ /^uuid=/) u = substr($i, 6)
        if (match($0, /\[display [0-9]+\]/)) {
            s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s)
            print s, u
        }
    }' "$TMP/baseline.txt" > "$TMP/baseline-current.txt"
}

poll_current() {  # display uuid [timeout_s=8] — wait until display's current == uuid
    local d="$1" want="$2" t="${3:-8}" i=0
    local steps=$((t * 4))
    while [ "$i" -lt "$steps" ]; do
        [ "$(current_uuid "$d")" = "$want" ] && return 0
        sleep 0.25; i=$((i + 1))
    done
    [ "$(current_uuid "$d")" = "$want" ]
}

restore_spaces() {
    [ -s "$TMP/baseline-current.txt" ] || return 0
    while read -r d want; do
        [ -z "$want" ] && continue
        [ "$(current_uuid "$d")" = "$want" ] && continue
        "$BIN" --switch "$want" >/dev/null 2>&1
        if ! poll_current "$d" "$want" 8; then
            "$BIN" --switch "$want" >/dev/null 2>&1
            poll_current "$d" "$want" 8 || say "WARN: could not restore display $d to $want"
        fi
    done < "$TMP/baseline-current.txt"
}

ensure_app() {
    pgrep -qf "SpeedySpaces.app/Contents/MacOS/SpeedySpaces" && return 0
    say "INFO app not running — launching"
    open -n "$APP"
    sleep 2
}

save_default() {
    touch "$TMP/def-$1.saved"
    defaults read "$DOMAIN" "$1" > "$TMP/def-$1.value" 2>/dev/null || rm -f "$TMP/def-$1.value"
}
restore_default() {
    [ -f "$TMP/def-$1.saved" ] || return 0
    if [ -f "$TMP/def-$1.value" ]; then
        defaults write "$DOMAIN" "$1" "$(cat "$TMP/def-$1.value")"
    else
        defaults delete "$DOMAIN" "$1" >/dev/null 2>&1 || true
    fi
}

diag_mark() { MARK=$(stat -f%z "$DIAG" 2>/dev/null || echo 0); }
diag_tail() { tail -c "+$((MARK + 1))" "$DIAG" 2>/dev/null || true; }

json_ok() { python3 -m json.tool < "$1" > /dev/null 2>&1; }
# Normalized JSON for diffing: the spaces array's export order follows dictionary
# iteration (unstable across processes), so sort it by uuid; volatile framework prefs
# (window frames, tab selection) churn while the app runs, so drop them.
json_norm() {
    python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
if isinstance(r.get("spaces"), list):
    r["spaces"] = sorted(r["spaces"], key=lambda e: str(e.get("uuid")))
if isinstance(r.get("prefs"), dict):
    r["prefs"] = {k: v for k, v in r["prefs"].items()
                  if not k.startswith(("NS", "Apple")) and "Window Frame" not in k}
print(json.dumps(r, sort_keys=True))' "$1"
}

# Directional commands act on the display under the POINTER — park it on the primary
# display before every one so a human moving the mouse can't re-route the test.
park() { "$BIN" --post-mouse 100 100 > /dev/null 2>&1; sleep 0.2; }

# Force display $1's current to uuid $2 (used to re-sync between subsections so one
# timing miss can't cascade).
force_current() {
    [ "$(current_uuid "$1")" = "$2" ] && return 0
    "$BIN" --switch "$2" > /dev/null 2>&1
    poll_current "$1" "$2" 10
}

cleanup() {
    restore_spaces
    restore_default hotkeyDebugLog
    restore_default hotkeyWrapAround
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

# ---------- tier: unit ----------

tier_unit() {
    TIER=unit
    local out="$TMP/selftest.txt"
    "$BIN" --selftest > "$out" 2>&1
    local code=$? fails passes
    fails=$(grep -c '^FAIL' "$out"); passes=$(grep -c '^PASS' "$out")
    [ "$code" -eq 0 ] && ok "--selftest exits 0" || bad "--selftest exits 0" "exit $code"
    [ "$fails" -eq 0 ] && ok "no FAIL lines" || { bad "no FAIL lines" "$fails failing"; grep '^FAIL' "$out"; }
    [ "$passes" -ge 250 ] && ok "check-count floor ($passes >= 250, catches dropped groups)" \
                          || bad "check-count floor" "only $passes PASS lines"
}

# ---------- tier: ro (read-only integration) ----------

tier_ro() {
    TIER=ro
    local out n
    out="$TMP/dump.txt"
    if dump > "$out" && grep -qE '^Found [0-9]+ space' "$out"; then
        ok "--dump runs and reports a count"
    else
        bad "--dump runs and reports a count"; return
    fi
    n=$(grep -c 'uuid=' "$out")
    [ "$n" -ge 1 ] && ok "--dump lists at least one space ($n)" || bad "--dump lists at least one space"

    # Exactly one *CURRENT* per display group.
    local d_all d_cur cur_total
    d_all=$(awk '{ if (match($0, /\[display [0-9]+\]/)) print substr($0, RSTART, RLENGTH) }' "$out" | sort -u | wc -l | tr -d ' ')
    d_cur=$(awk '/\*CURRENT\*/ { if (match($0, /\[display [0-9]+\]/)) print substr($0, RSTART, RLENGTH) }' "$out" | sort -u | wc -l | tr -d ' ')
    cur_total=$(grep -c '\*CURRENT\*' "$out")
    [ "$d_all" = "$d_cur" ] && [ "$cur_total" = "$d_all" ] \
        && ok "exactly one current space per display ($d_all displays)" \
        || bad "exactly one current space per display" "displays=$d_all with-current=$d_cur markers=$cur_total"

    local malformed
    malformed=$(grep -o 'uuid=[^ ]*' "$out" | grep -cEv '^uuid=[0-9A-Fa-f-]{36}$')
    [ "$malformed" -eq 0 ] && ok "uuids well-formed" || bad "uuids well-formed" "$malformed malformed"

    "$BIN" --dump-raw-spaces > "$TMP/raw.txt" 2>&1 && [ -s "$TMP/raw.txt" ] \
        && ok "--dump-raw-spaces" || bad "--dump-raw-spaces"
    "$BIN" --dump-windows > /dev/null 2>&1 && ok "--dump-windows" || bad "--dump-windows"
    "$BIN" --symbols > "$TMP/symbols.txt" 2>&1 && [ -s "$TMP/symbols.txt" ] \
        && ok "--symbols" || bad "--symbols"
    "$BIN" --probe-space-apis > "$TMP/apis.txt" 2>&1 && grep -q "CGSMainConnectionID" "$TMP/apis.txt" \
        && ok "--probe-space-apis (dlsym report)" || bad "--probe-space-apis"

    if "$BIN" --export-config "$TMP/cfg-ro.json" > /dev/null 2>&1 && json_ok "$TMP/cfg-ro.json"; then
        ok "--export-config writes valid JSON"
        python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert "prefs" in r and "spaces" in r' "$TMP/cfg-ro.json" 2>/dev/null \
            && ok "config backup has prefs + spaces keys" || bad "config backup has prefs + spaces keys"
    else
        bad "--export-config writes valid JSON"
    fi

    local as="$HOME/Library/Application Support/SpeedySpaces" f bad_json=0
    for f in spaces.json wallpapers.json; do
        [ -f "$as/$f" ] && ! json_ok "$as/$f" && bad_json=$((bad_json + 1))
    done
    [ "$bad_json" -eq 0 ] && ok "App Support JSON stores parse" || bad "App Support JSON stores parse"
}

# ---------- tier: live (running app, restores state) ----------

# cyclic successor/predecessor of $2 within display $1 (uses the snapshot)
neighbor() {  # display base fwd|back
    disp_uuids "$1" > "$TMP/du.txt"
    local n i j
    n=$(wc -l < "$TMP/du.txt" | tr -d ' ')
    i=$(grep -n "^$2$" "$TMP/du.txt" | cut -d: -f1)
    [ -z "$i" ] || [ "$n" -eq 0 ] && return 1
    if [ "$3" = "fwd" ]; then j=$((i % n + 1)); else j=$((i - 1)); [ "$j" -lt 1 ] && j=$n; fi
    sed -n "${j}p" "$TMP/du.txt"
}

detect_changed_display() {  # prints "display uuid" for the first display whose current moved
    local d want cur
    while read -r d want; do
        cur=$(current_uuid "$d")
        if [ -n "$cur" ] && [ "$cur" != "$want" ]; then echo "$d $cur"; return 0; fi
    done < "$TMP/baseline-current.txt"
    return 1
}

tier_live() {
    TIER=live
    ensure_app
    save_default hotkeyDebugLog
    save_default hotkeyWrapAround
    defaults write "$DOMAIN" hotkeyDebugLog -bool true
    defaults write "$DOMAIN" hotkeyWrapAround -bool true   # tests assume wrap semantics
    touch "$DIAG"
    snapshot
    "$BIN" --post-mouse 100 100 > /dev/null 2>&1   # park pointer on the primary display
    sleep 0.3

    # -- 1. --next advances the pointer display; discovers which display that is --
    local D="" newu="" basecur="" expect ch i
    diag_mark
    "$BIN" --next > /dev/null 2>&1
    for i in $(seq 1 32); do
        ch=$(detect_changed_display) && break
        sleep 0.25
    done
    if [ -n "${ch:-}" ]; then
        D=${ch%% *}; newu=${ch#* }
        basecur=$(awk -v d="$D" '$1 == d { print $2 }' "$TMP/baseline-current.txt")
        expect=$(neighbor "$D" "$basecur" fwd)
        [ "$newu" = "$expect" ] && ok "--next advances to the successor (display $D)" \
                                || bad "--next advances to the successor" "got $newu want $expect"
    else
        bad "--next advances to the successor" "no display changed in 8s"
        restore_spaces; return
    fi

    # -- 2. --prev returns to the baseline --
    park
    "$BIN" --prev > /dev/null 2>&1
    poll_current "$D" "$basecur" && ok "--prev returns to baseline" || bad "--prev returns to baseline"

    # -- 3. --switch '#k' (1-based index on the pointer display) --
    local k=1 target
    target=$(disp_uuids "$D" | sed -n "${k}p")
    [ "$target" = "$basecur" ] && { k=2; target=$(disp_uuids "$D" | sed -n "${k}p"); }
    force_current "$D" "$basecur" || true
    if [ -n "$target" ]; then
        park
        "$BIN" --switch "#$k" > /dev/null 2>&1
        poll_current "$D" "$target" && ok "--switch '#$k' lands on index $k" \
                                    || bad "--switch '#$k' lands on index $k"
        "$BIN" --switch "$basecur" > /dev/null 2>&1
        poll_current "$D" "$basecur" && ok "--switch <uuid> restores baseline" \
                                     || bad "--switch <uuid> restores baseline"
    else
        note "--switch '#k' skipped (single-space display)"
    fi

    # -- 4. --back toggles between the last two spaces --
    force_current "$D" "$basecur" || true
    if [ -n "$target" ] && "$BIN" --switch "$target" > /dev/null 2>&1 && poll_current "$D" "$target"; then
        park
        "$BIN" --back > /dev/null 2>&1
        poll_current "$D" "$basecur" && ok "--back returns to previous space" \
                                     || bad "--back returns to previous space"
        park
        "$BIN" --back > /dev/null 2>&1
        poll_current "$D" "$target" && ok "--back toggles forward again" \
                                    || bad "--back toggles forward again"
    else
        note "--back test skipped (setup switch unavailable)"
    fi

    # -- 5. --fire-hotkey routes through the hotkey dispatcher + diag log --
    force_current "$D" "$basecur" || true
    diag_mark
    park
    "$BIN" --fire-hotkey nextSpace > /dev/null 2>&1
    expect=$(neighbor "$D" "$basecur" fwd)
    poll_current "$D" "$expect" && ok "--fire-hotkey nextSpace switches" \
                                || bad "--fire-hotkey nextSpace switches"
    diag_tail | grep -q "debugFire nextSpace" && ok "diag log records debugFire" \
                                              || bad "diag log records debugFire"
    park
    "$BIN" --fire-hotkey previousSpace > /dev/null 2>&1
    poll_current "$D" "$basecur" && ok "--fire-hotkey previousSpace returns" \
                                 || bad "--fire-hotkey previousSpace returns"

    # -- 6. wrap-around at both ends (hotkeyWrapAround=true) --
    local first last
    first=$(disp_uuids "$D" | head -1)
    last=$(disp_uuids "$D" | tail -1)
    if [ "$first" != "$last" ]; then
        if force_current "$D" "$last"; then
            park
            "$BIN" --fire-hotkey nextSpace > /dev/null 2>&1
            poll_current "$D" "$first" && ok "wrap: last -> first" || bad "wrap: last -> first"
            park
            "$BIN" --fire-hotkey previousSpace > /dev/null 2>&1
            poll_current "$D" "$last" && ok "wrap: first -> last" || bad "wrap: first -> last"
        else
            bad "wrap setup switch to last"
        fi
        force_current "$D" "$basecur" || bad "restore after wrap test"
    else
        note "wrap test skipped (single-space display)"
    fi

    # -- 7. switch outcome line shape in the diag log --
    diag_tail | grep -qE ' · OK · [0-9]+ ms' && ok "outcome summary logged (· OK · N ms)" \
                                             || bad "outcome summary logged"

    # -- 8. switcher HUD: show + frames side door --
    local total shown
    total=$(dump | grep -c 'uuid=')
    diag_mark
    "$BIN" --show-switcher 3 > /dev/null 2>&1
    sleep 1
    "$BIN" --switcher-debug frames > /dev/null 2>&1
    sleep 0.5
    shown=$(diag_tail | awk '/switcher frames/ { if (match($0, / n=[0-9]+/)) s += substr($0, RSTART + 3, RLENGTH - 3) } END { print s + 0 }')
    [ "$shown" = "$total" ] && ok "HUD frames reports every space ($shown/$total tiles)" \
                            || bad "HUD frames reports every space" "$shown of $total"
    sleep 2.5   # let the flash expire

    # -- 9. hold-chord cycle via the debug side door --
    "$BIN" --fire-hotkey holdSwitcher:down > /dev/null 2>&1
    sleep 1.2
    "$BIN" --fire-hotkey holdSwitcher:up > /dev/null 2>&1
    sleep 0.7
    pgrep -qf "SpeedySpaces.app/Contents/MacOS/SpeedySpaces" \
        && ok "hold-chord down/up cycle leaves app healthy" || bad "hold-chord cycle" "app died"

    # -- 10. engine probes (own process, direct CGS) --
    local gidx
    expect=$(neighbor "$D" "$basecur" fwd)
    gidx=$(dump | sed -n 's/.*uuid=\([^ ]*\).*/\1/p' | grep -n "^$expect$" | cut -d: -f1)
    if [ -n "$gidx" ] && force_current "$D" "$basecur"; then
        gidx=$((gidx - 1))
        park
        if "$BIN" --probe-switch gesture "$gidx" > "$TMP/probe-gesture.txt" 2>&1; then
            ok "--probe-switch gesture verifies"
        else
            bad "--probe-switch gesture verifies" "$(tail -1 "$TMP/probe-gesture.txt")"
        fi
        if force_current "$D" "$basecur"; then
            park
            # Environment fact, not an app defect: synthetic keys are dropped on this
            # host, so the keyboard engine should fail cleanly. If that ever flips,
            # report it, but don't fail the suite.
            if "$BIN" --probe-switch keyboard "$gidx" > /dev/null 2>&1; then
                note "keyboard engine unexpectedly verified — synthetic keys may work now"
                force_current "$D" "$basecur" || true
            else
                ok "--probe-switch keyboard fails cleanly (synthetic keys dead on this host)"
            fi
        fi
    else
        note "engine probes skipped (could not establish baseline)"
    fi

    # -- 11. config export/import round-trip is lossless --
    if "$BIN" --export-config "$TMP/cfg1.json" > /dev/null 2>&1 \
        && "$BIN" --import-config "$TMP/cfg1.json" > "$TMP/import.txt" 2>&1 \
        && grep -q '^imported:' "$TMP/import.txt" \
        && "$BIN" --export-config "$TMP/cfg2.json" > /dev/null 2>&1; then
        if [ "$(json_norm "$TMP/cfg1.json")" = "$(json_norm "$TMP/cfg2.json")" ]; then
            ok "config export -> import -> export is lossless"
        else
            bad "config export -> import -> export is lossless" "re-export differs"
        fi
    else
        bad "config import/export round-trip" "$(cat "$TMP/import.txt" 2>/dev/null | tail -1)"
    fi

    restore_spaces
    restore_default hotkeyWrapAround
    restore_default hotkeyDebugLog
}

# ---------- tier: destructive (self-restoring desktop mutations) ----------

d0_ids() { dump | awk '/\[display 0\]/ { for (i = 1; i <= NF; i++) if ($i ~ /^id=/) print substr($i, 4) }'; }

tier_destructive() {
    TIER=destructive
    ensure_app
    snapshot
    say ""
    say "*** DESTRUCTIVE TIER: about to reorder + add/remove desktops (all self-restoring)."
    say "*** Ctrl-C within 3 seconds to abort."
    sleep 3

    local before after
    dump > "$TMP/d-before.txt"

    # -- 1. reorder probe (its own baseline/tripwires/restore inside) --
    if "$BIN" --probe-space-reorder swap > "$TMP/reorder.txt" 2>&1; then
        ok "--probe-space-reorder swap exits 0"
    else
        bad "--probe-space-reorder swap exits 0" "$(tail -1 "$TMP/reorder.txt")"
    fi
    sleep 1
    before=$(grep -o 'uuid=[^ ]*' "$TMP/d-before.txt"); after=$(dump | grep -o 'uuid=[^ ]*')
    if [ "$before" = "$after" ]; then
        ok "space order restored after reorder probe"
    else
        bad "space order restored after reorder probe" "attempting recovery"
        "$BIN" --set-space-order "$(awk '/\[display 0\]/ { for (i=1;i<=NF;i++) if ($i ~ /^id=/) printf "%s%s", (c++?",":""), substr($i,4) }' "$TMP/d-before.txt")" > /dev/null 2>&1
        sleep 1
        if [ "$(dump | grep -o 'uuid=[^ ]*')" = "$before" ]; then
            say "INFO recovery succeeded"
        else
            cp "$TMP/d-before.txt" /tmp/speedyspaces-baseline-order.txt
            say "ERROR: manual recovery needed — desired order saved to /tmp/speedyspaces-baseline-order.txt"
        fi
    fi

    # -- 2. --set-space-order transposes and restores the last two display-0 desktops --
    local ids n last two_swapped orig cur0
    ids=$(d0_ids | tr '\n' ',' | sed 's/,$//')
    n=$(d0_ids | wc -l | tr -d ' ')
    cur0=$(current_uuid 0)
    last=$(disp_uuids 0 | tail -1)
    if [ "$n" -ge 3 ] && [ "$last" != "$cur0" ] && [ "$(disp_uuids 0 | tail -2 | head -1)" != "$cur0" ]; then
        two_swapped=$(python3 -c 'import sys; a=sys.argv[1].split(","); a[-1],a[-2]=a[-2],a[-1]; print(",".join(a))' "$ids")
        "$BIN" --set-space-order "$two_swapped" > /dev/null 2>&1
        sleep 1
        [ "$(d0_ids | tr '\n' ',' | sed 's/,$//')" = "$two_swapped" ] \
            && ok "--set-space-order applies a transposition" || bad "--set-space-order applies a transposition"
        "$BIN" --set-space-order "$ids" > /dev/null 2>&1
        sleep 1
        [ "$(d0_ids | tr '\n' ',' | sed 's/,$//')" = "$ids" ] \
            && ok "--set-space-order restores the original order" || bad "--set-space-order restores the original order" "wanted $ids"
    else
        note "--set-space-order test skipped (needs >=3 desktops with the last two non-current)"
    fi

    # -- 3. space-mutation probe self-restores --
    if "$BIN" --probe-space-mutation > "$TMP/mutation.txt" 2>&1; then
        ok "--probe-space-mutation exits 0"
    else
        bad "--probe-space-mutation exits 0" "$(tail -1 "$TMP/mutation.txt")"
    fi
    sleep 1
    [ "$(dump | grep -o 'uuid=[^ ]*')" = "$before" ] && ok "spaces unchanged after mutation probe" \
                                                     || bad "spaces unchanged after mutation probe"

    # -- 4. add + remove a desktop via the Mission Control choreography --
    local total added_d added_ord i
    total=$(dump | grep -c 'uuid=')
    if "$BIN" --probe-add-desktop > "$TMP/add.txt" 2>&1; then
        ok "--probe-add-desktop exits 0"
        for i in $(seq 1 20); do
            [ "$(dump | grep -c 'uuid=')" = "$((total + 1))" ] && break
            sleep 0.5
        done
        if [ "$(dump | grep -c 'uuid=')" = "$((total + 1))" ]; then
            ok "desktop count is N+1 after add"
            # The new desktop lands at the end of the primary display's list (0-based ordinal).
            added_ord=$(( $(dump | awk '/\[display 0\]/' | wc -l | tr -d ' ') - 1 ))
            if "$BIN" --probe-remove-desktop "$added_ord" > "$TMP/remove.txt" 2>&1; then
                ok "--probe-remove-desktop exits 0"
            else
                bad "--probe-remove-desktop exits 0" "$(tail -1 "$TMP/remove.txt") — remove the extra desktop by opening Mission Control (empty desktops are auto-reaped) or dragging it closed"
            fi
            for i in $(seq 1 20); do
                [ "$(dump | grep -c 'uuid=')" = "$total" ] && break
                sleep 0.5
            done
            [ "$(dump | grep -c 'uuid=')" = "$total" ] && ok "desktop count back to N after remove" \
                || bad "desktop count back to N after remove" "open Mission Control once to auto-reap the empty desktop"
        else
            bad "desktop count is N+1 after add" "count never changed"
        fi
    else
        bad "--probe-add-desktop exits 0" "$(tail -1 "$TMP/add.txt")"
    fi

    restore_spaces
}

# ---------- main ----------

mode="${1:-all}"
if [ ! -x "$BIN" ]; then
    say "INFO binary missing — building"
    (cd "$ROOT" && ./build.sh) || { say "build failed"; exit 125; }
fi

case "$mode" in
    unit)        tier_unit ;;
    ro)          tier_ro ;;
    live)        tier_live ;;
    destructive) tier_destructive ;;
    all)         tier_unit; tier_ro; tier_live; tier_destructive ;;
    *) say "usage: tests/test.sh [unit|ro|live|destructive|all]"; exit 2 ;;
esac

say ""
say "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 125 ] && exit 125
exit "$FAIL"
