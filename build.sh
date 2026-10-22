#!/bin/bash
# Builds Snapkeep.app with swiftc (no Xcode needed) and signs it ad hoc.
#
#   ./build.sh            build to build/Snapkeep.app
#   ./build.sh install    build, replace /Applications/Snapkeep.app and launch it
#   ./build.sh test       build and run the self-tests
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=Snapkeep
BUNDLE_ID=com.stanimir.snapkeep
BUILD=build
APP="$BUILD/$APP_NAME.app"
TARGET=arm64-apple-macos14.0
SWIFT_FLAGS=(-O -swift-version 5 -target "$TARGET" -sdk "$(xcrun --show-sdk-path)")

build_app() {
    echo "==> Compiling"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    swiftc "${SWIFT_FLAGS[@]}" -o "$APP/Contents/MacOS/$APP_NAME" Sources/Snapkeep/*.swift

    cp Resources/Info.plist "$APP/Contents/Info.plist"
    if [[ ! -f Resources/AppIcon.icns ]]; then
        echo "==> Drawing the app icon"
        scripts/make-icon.sh Resources/AppIcon.icns
    fi
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

    echo "==> Signing ad hoc"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
    codesign --verify --strict "$APP"
    echo "Built $APP"
}

run_tests() {
    echo "==> Compiling self-tests"
    mkdir -p "$BUILD"
    local sources=()
    for file in Sources/Snapkeep/*.swift; do
        case "$(basename "$file")" in
            main.swift|AppDelegate.swift) ;;
            *) sources+=("$file") ;;
        esac
    done
    swiftc "${SWIFT_FLAGS[@]}" -parse-as-library -o "$BUILD/selftest" "${sources[@]}" Tests/SelfTest.swift
    "$BUILD/selftest"
}

install_app() {
    echo "==> Installing to /Applications"
    pkill -x "$APP_NAME" 2>/dev/null && sleep 0.5 || true
    rm -rf "/Applications/$APP_NAME.app"
    ditto "$APP" "/Applications/$APP_NAME.app"
    # Every ad-hoc build has a new signature, so the old Screen Recording grant no longer
    # matches. Drop it so macOS asks again cleanly instead of showing a stale switch.
    tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
    open "/Applications/$APP_NAME.app"
    echo "Installed and launched. Grant Screen Recording again when macOS asks."
}

case "${1:-build}" in
    build) build_app ;;
    install) build_app; install_app ;;
    test) run_tests ;;
    *) echo "usage: $0 [build|install|test]" >&2; exit 2 ;;
esac
