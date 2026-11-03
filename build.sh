#!/usr/bin/env bash
# Build AppMixer.app with SwiftPM (Command Line Tools are enough, no Xcode needed).
#
#   ./build.sh            build build/AppMixer.app
#   ./build.sh install    build, then copy to ~/Applications and launch it
#   ./build.sh run        build, then launch from build/
#
# Env:
#   SIGN_ID    codesign identity (default "-" = ad-hoc). A stable identity, e.g. a self-signed
#              "AppMixer Dev" code-signing certificate, keeps the audio permission across rebuilds.
#   BUNDLE_ID  default dev.appmixer.AppMixer
#   VERSION    default 0.1.0
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=AppMixer
BUNDLE_ID=${BUNDLE_ID:-dev.appmixer.AppMixer}
VERSION=${VERSION:-0.1.0}
BUILD_NUMBER=${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}
SIGN_ID=${SIGN_ID:--}
APP="build/$APP_NAME.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed with: $SIGN_ID)"

quit_running() {
    if pgrep -x "$APP_NAME" >/dev/null; then
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || pkill -x "$APP_NAME" || true
        sleep 1
    fi
}

case "${1:-}" in
    install)
        quit_running
        mkdir -p "$HOME/Applications"
        rm -rf "$HOME/Applications/$APP_NAME.app"
        cp -R "$APP" "$HOME/Applications/"
        open "$HOME/Applications/$APP_NAME.app"
        echo "Installed to ~/Applications/$APP_NAME.app and launched (look for the slider icon in the menu bar)."
        ;;
    run)
        quit_running
        open "$APP"
        ;;
    "") ;;
    *) echo "unknown command: $1" >&2; exit 1 ;;
esac
