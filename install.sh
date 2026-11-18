#!/bin/bash
# Build, sign and install Screenshot 720p Converter, then restart its background agent.
#   ./install.sh               build + install
#   ./install.sh --build-only  build into build/ without touching the installed app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="Screenshot 720p Converter"
LABEL="local.yen.screenshot720p"
INSTALLED="/Applications/$NAME.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
BACKUPS="$HOME/Library/Application Support/Screenshot720p/backup"
BUILT="$ROOT/build/$NAME.app"
DOMAIN="gui/$(id -u)"

echo "==> Running tests"
/Library/Frameworks/Python.framework/Versions/3.13/bin/python3 -m unittest discover -s "$ROOT/tests" -q

echo "==> Building"
rm -rf "$BUILT"
mkdir -p "$BUILT/Contents/MacOS" "$BUILT/Contents/Resources"
swiftc -O -module-cache-path "$ROOT/build/module-cache" -o "$BUILT/Contents/MacOS/ConverterLauncher" \
    "$ROOT/src/main.swift" "$ROOT/src/ProgressPanel.swift" "$ROOT/src/Notifier.swift"
cp "$ROOT/support/Info.plist" "$BUILT/Contents/Info.plist"
cp "$ROOT/src/screenshot_720p.py" "$BUILT/Contents/Resources/screenshot_720p.py"
codesign --force --sign - --identifier "$LABEL" "$BUILT"
codesign --verify --deep --strict "$BUILT"
echo "    built $BUILT"
[[ "${1:-}" == "--build-only" ]] && exit 0

echo "==> Backing up installed app"
mkdir -p "$BACKUPS"
BACKUP="$BACKUPS/$NAME $(date +%Y%m%d-%H%M%S).app"
[[ -d "$INSTALLED" ]] && ditto "$INSTALLED" "$BACKUP" && echo "    $BACKUP"

echo "==> Waiting for any conversion in progress (up to 10 min)"
for _ in $(seq 1 600); do
    pgrep -f "$INSTALLED/Contents/Resources/screenshot_720p.py" >/dev/null || break
    sleep 1
done
if pgrep -f "$INSTALLED/Contents/Resources/screenshot_720p.py" >/dev/null; then
    echo "A conversion is still running; try again later. Nothing was changed." >&2
    exit 1
fi

echo "==> Stopping agent"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for _ in $(seq 1 30); do
    pgrep -f "$INSTALLED/Contents/MacOS/ConverterLauncher" >/dev/null || break
    sleep 1
done

restore() {
    echo "!! Install failed; restoring previous app" >&2
    if [[ -d "${BACKUP:-}" ]]; then rm -rf "$INSTALLED"; ditto "$BACKUP" "$INSTALLED"; fi
    launchctl bootstrap "$DOMAIN" "$AGENT" 2>/dev/null || true
}
trap restore ERR

echo "==> Installing"
rm -rf "$INSTALLED"
ditto "$BUILT" "$INSTALLED"
codesign --verify --deep --strict "$INSTALLED"
cp "$ROOT/support/$LABEL.plist" "$AGENT"
launchctl bootstrap "$DOMAIN" "$AGENT"
trap - ERR

sleep 2
launchctl list | grep "$LABEL" || { echo "Agent is not running" >&2; exit 1; }
echo "==> Done"
