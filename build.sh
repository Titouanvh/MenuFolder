#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/MenuFolder.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

swiftc -O \
    -target "$(uname -m)-apple-macosx14.0" \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework ScreenCaptureKit \
    "$ROOT_DIR/Sources/main.swift" \
    "$ROOT_DIR/Sources/AppDelegate.swift" \
    "$ROOT_DIR/Sources/StatusBarController.swift" \
    "$ROOT_DIR/Sources/MenuBarService.swift" \
    "$ROOT_DIR/Sources/FolderPanel.swift" \
    -o "$MACOS_DIR/MenuFolder"

cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

codesign --force --sign - --identifier "com.local.MenuFolder" "$APP_BUNDLE"

# Ad-hoc rebuilds change the binary CDHash; clear stale TCC entries so System Settings accepts re-enabling.
tccutil reset Accessibility com.local.MenuFolder >/dev/null 2>&1 || true
tccutil reset ScreenCapture com.local.MenuFolder >/dev/null 2>&1 || true

echo "Built: $APP_BUNDLE"
