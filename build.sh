#!/bin/zsh
# Builds MouseSkins.app, installs it to ~/Applications and links the CLI.
#   ./build.sh          build + install + launch
#   ./build.sh --no-run build + install only
set -euo pipefail
cd "${0:A:h}"

APP=build/MouseSkins.app
DEST="$HOME/Applications/MouseSkins.app"
CLI="$HOME/.local/bin/mouseskins"

rm -rf build && mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -import-objc-header Sources/CGSPrivate.h \
  -o "$APP/Contents/MacOS/MouseSkins" Sources/*.swift

cp Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources" && cp Icon/AppIcon.icns "$APP/Contents/Resources/"   # redraw: see Icon/make-icon.swift
codesign --force --sign - --identifier dev.christianaguilar.mouseskins "$APP"

pkill -x MouseSkins 2>/dev/null && sleep 0.5 || true
mkdir -p "${DEST:h}" && rm -rf "$DEST" && cp -R "$APP" "$DEST"
mkdir -p "${CLI:h}" && ln -sf "$DEST/Contents/MacOS/MouseSkins" "$CLI"
echo "Installed $DEST (CLI: $CLI)"

[[ "${1:-}" == "--no-run" ]] || open -g "$DEST" --args --background
