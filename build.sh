#!/bin/bash
# Builds SpeedySpaces.app using only the Swift toolchain / Command Line Tools
# (no full Xcode required). Output: build/SpeedySpaces.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/Sources/SpeedySpaces"
BUILD="$ROOT/build"
APP="$BUILD/SpeedySpaces.app"
DEPLOY_TARGET="14.0"
ARCH="$(uname -m)"

echo "==> Cleaning"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Info.plist + resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Compiling C shim"
clang -c "$SRC/CGSShim.c" -o "$BUILD/CGSShim.o" \
    -target "${ARCH}-apple-macos${DEPLOY_TARGET}"

echo "==> Compiling Swift + linking"
swiftc \
    -o "$APP/Contents/MacOS/SpeedySpaces" \
    -target "${ARCH}-apple-macos${DEPLOY_TARGET}" \
    -import-objc-header "$SRC/CGSPrivate.h" \
    -framework AppKit \
    -framework ServiceManagement \
    -framework Carbon \
    -framework AppIntents \
    "$BUILD/CGSShim.o" \
    "$SRC"/*.swift

# --- App Intents metadata (native macOS Shortcuts actions) — best-effort, guarded ---
# Shortcuts discovery needs Apple's App Intents metadata bundle, produced by
# `appintentsmetadataprocessor` — a tool that ships only with FULL Xcode, not the Command
# Line Tools. When a full Xcode is present we emit Swift const-values and run the extractor
# (must land before codesign so it's covered); otherwise we skip cleanly. Either way the app
# runs and the speedyspaces:// URL scheme + CLI work — this only governs whether the actions
# show up natively in the Shortcuts app.
AI_DEV=""
for dev in "$(xcode-select -p 2>/dev/null)" /Applications/Xcode*.app/Contents/Developer; do
    if [ -x "$dev/Toolchains/XcodeDefault.xctoolchain/usr/bin/appintentsmetadataprocessor" ]; then
        AI_DEV="$dev"; break
    fi
done
if [ -n "$AI_DEV" ]; then
    echo "==> App Intents: extracting Shortcuts metadata (via $AI_DEV)"
    AI_TC="$AI_DEV/Toolchains/XcodeDefault.xctoolchain"
    AI_SDK="$(xcrun --show-sdk-path)"
    AI_XCV="$(defaults read "$AI_DEV/../version" ProductBuildVersion 2>/dev/null || echo 0)"
    # Protocol names are UNQUALIFIED (no `AppIntents.` prefix) — the const gatherer matches
    # nothing with a module prefix.
    printf '%s\n' '["AppIntent","AppEntity","AppEnum","EntityQuery","EntityPropertyQuery","DynamicOptionsProvider","AppShortcutsProvider","PersistentAppEntity","EntityIdentifierConvertible"]' \
        > "$BUILD/appintents-protocols.json"
    # A separate whole-module pass emits const-values only. `-module-name SpeedySpaces` is
    # required so the extracted type names match `--module-name` below (otherwise they take
    # the -o basename and the extractor can't resolve them); the object output is discarded.
    if swiftc -wmo -module-name SpeedySpaces \
        -target "${ARCH}-apple-macos${DEPLOY_TARGET}" \
        -import-objc-header "$SRC/CGSPrivate.h" \
        -framework AppKit -framework ServiceManagement -framework Carbon -framework AppIntents \
        -emit-const-values-path "$BUILD/SpeedySpaces.swiftconstvalues" \
        -Xfrontend -const-gather-protocols-file -Xfrontend "$BUILD/appintents-protocols.json" \
        -c -o "$BUILD/appintents-const.o" \
        "$SRC"/*.swift 2>/dev/null
    then
        ls "$SRC"/*.swift > "$BUILD/appintents-sources.txt"
        echo "$BUILD/SpeedySpaces.swiftconstvalues" > "$BUILD/appintents-constvals.txt"
        if "$AI_TC/usr/bin/appintentsmetadataprocessor" \
            --toolchain-dir "$AI_TC" --sdk-root "$AI_SDK" --module-name SpeedySpaces \
            --target-triple "${ARCH}-apple-macos${DEPLOY_TARGET}" \
            --deployment-target "$DEPLOY_TARGET" --platform-family macOS --xcode-version "$AI_XCV" \
            --source-file-list "$BUILD/appintents-sources.txt" \
            --swift-const-vals-list "$BUILD/appintents-constvals.txt" \
            --output "$APP/Contents/Resources" >/dev/null 2>&1
        then
            echo "==> App Intents: Metadata.appintents written"
        else
            echo "==> App Intents: extractor failed — skipping (URL scheme + CLI still work)"
        fi
    else
        echo "==> App Intents: const-values pass failed — skipping (URL scheme + CLI still work)"
    fi
else
    echo "==> App Intents: no full Xcode found — skipping native Shortcuts actions (URL scheme + CLI still work)"
fi

# Sign with a STABLE identity if provided, so macOS remembers the Accessibility grant
# across rebuilds. Ad-hoc signatures change every build, which makes the system forget
# the grant and re-prompt on every launch — set SIGN_IDENTITY to avoid that.
#   SIGN_IDENTITY="Apple Development: you@example.com"  ./build.sh
# (Run `security find-identity -v -p codesigning` to list available identities.)
SIGN="${SIGN_IDENTITY:-}"
if [ -z "$SIGN" ]; then
    # Default to a stable Apple Development identity when one exists: ad-hoc signatures
    # change every build, which makes macOS silently drop the Accessibility grant — and
    # with it space switching AND the Mission Control dismissal watch.
    # Use the certificate hash — common names can be ambiguous (multiple certs).
    SIGN=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/Apple Development/ {print $2; exit}')
fi
SIGN="${SIGN:--}"
if [ "$SIGN" = "-" ]; then
    echo "==> Ad-hoc code signing (grant will NOT persist across rebuilds)"
else
    echo "==> Code signing with identity: $SIGN"
fi
codesign --force --sign "$SIGN" \
    --entitlements "$ROOT/SpeedySpaces.entitlements" \
    --options runtime \
    "$APP" 2>/dev/null || \
codesign --force --sign "$SIGN" \
    --entitlements "$ROOT/SpeedySpaces.entitlements" \
    "$APP"

echo "==> Built $APP"

# If SpeedySpaces is already running, relaunch so this fresh build takes over. macOS `open` won't
# relaunch a running LSUIElement agent — it just re-activates the old one — so a rebuild would
# otherwise keep running stale code. `open -n` forces a new instance; the app terminates the
# stale one on launch (newest wins).
if pgrep -f "SpeedySpaces.app/Contents/MacOS/SpeedySpaces" >/dev/null 2>&1; then
    echo "==> Relaunching (replacing the running instance)"
    open -n "$APP"
fi

echo "    Run with: open \"$APP\"   (or) \"$APP/Contents/MacOS/SpeedySpaces\""
