#!/bin/zsh
# Builds msig.app, installs it to ~/Applications and links the CLI.
#   ./build.sh          build + install + launch
#   ./build.sh --no-run build + install only
set -euo pipefail
cd "${0:A:h}"

APP=build/msig.app
DEST="$HOME/Applications/msig.app"
CLI="$HOME/.local/bin/msig"

rm -rf build && mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -import-objc-header Sources/CGSPrivate.h \
  -o "$APP/Contents/MacOS/msig" Sources/*.swift

cp Info.plist "$APP/Contents/"
codesign --force --sign - --identifier dev.christianaguilar.msig "$APP"

pkill -x msig 2>/dev/null && sleep 0.5 || true
mkdir -p "${DEST:h}" && rm -rf "$DEST" && cp -R "$APP" "$DEST"
mkdir -p "${CLI:h}" && ln -sf "$DEST/Contents/MacOS/msig" "$CLI"
echo "Installed $DEST (CLI: $CLI)"

[[ "${1:-}" == "--no-run" ]] || open -g "$DEST"
