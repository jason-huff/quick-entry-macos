#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${QUICK_ENTRY_APP_NAME:-Quick Entry}"
BUNDLE_ID="${QUICK_ENTRY_BUNDLE_ID:-io.github.jasonhuff.quick-entry}"
EXECUTABLE="QuickEntry"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"
ICONSET="$BUILD_DIR/QuickEntry.iconset"
INSTALL_DIR="${QUICK_ENTRY_INSTALL_DIR:-/Applications}"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
LAUNCH_AGENT_DIR="${QUICK_ENTRY_LAUNCH_AGENT_DIR:-$HOME/Library/LaunchAgents}"
LAUNCH_AGENT="$LAUNCH_AGENT_DIR/$BUNDLE_ID.plist"
TODO_FILE="${QUICK_ENTRY_TODO_FILE:-$HOME/QuickEntry/todo-processing.md}"
PI_MODEL="${QUICK_ENTRY_PI_MODEL:-}"
PI_THINKING="${QUICK_ENTRY_PI_THINKING:-off}"
LAUNCH_PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
PI_MODEL_PLIST=""
if [[ -n "$PI_MODEL" ]]; then
  PI_MODEL_PLIST="    <key>QUICK_ENTRY_PI_MODEL</key>
    <string>$PI_MODEL</string>"
fi

rm -rf "$APP" "$ICONSET"
mkdir -p "$MACOS" "$RESOURCES/skills/write-without-bullshit"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>QuickEntry</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

if [[ -f "$ROOT/icon.svg" ]]; then
  mkdir -p "$ICONSET"
  make_png() {
    local point_size="$1"
    local scale="$2"
    local pixel_size=$((point_size * scale))
    local suffix=""
    if [[ "$scale" == "2" ]]; then suffix="@2x"; fi
    local out="$ICONSET/icon_${point_size}x${point_size}${suffix}.png"

    if command -v rsvg-convert >/dev/null 2>&1; then
      rsvg-convert -w "$pixel_size" -h "$pixel_size" "$ROOT/icon.svg" -o "$out"
    elif command -v magick >/dev/null 2>&1; then
      magick -background none "$ROOT/icon.svg" -resize "${pixel_size}x${pixel_size}" "$out"
    else
      echo "warning: no SVG renderer found; skipping app icon" >&2
      return 1
    fi
  }

  for size in 16 32 128 256 512; do
    make_png "$size" 1 || break
    make_png "$size" 2 || break
  done

  if [[ -f "$ICONSET/icon_512x512@2x.png" ]]; then
    iconutil -c icns "$ICONSET" -o "$RESOURCES/QuickEntry.icns"
  fi
fi

install -m 755 "$ROOT/polish-writing.sh" "$RESOURCES/polish-writing.sh"
install -m 644 "$ROOT/skills/write-without-bullshit/SKILL.md" \
  "$RESOURCES/skills/write-without-bullshit/SKILL.md"

(
  cd "$ROOT"
  swiftc -gnone -parse-as-library QuickEntry.swift \
    -o "$MACOS/$EXECUTABLE" \
    -framework AppKit \
    -framework Carbon
)

# This local helper is intentionally unsigned. If macOS applies quarantine,
# clear it from the installed app rather than ad-hoc signing it.
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED_APP"
cp -R "$APP" "$INSTALL_DIR/"
xattr -cr "$INSTALLED_APP" 2>/dev/null || true
touch "$INSTALLED_APP"

mkdir -p "$LAUNCH_AGENT_DIR"
cat > "$LAUNCH_AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$BUNDLE_ID</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALLED_APP/Contents/MacOS/$EXECUTABLE</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$LAUNCH_PATH</string>
    <key>QUICK_ENTRY_TODO_FILE</key>
    <string>$TODO_FILE</string>
    <key>QUICK_ENTRY_PI_THINKING</key>
    <string>$PI_THINKING</string>
$PI_MODEL_PLIST
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>/tmp/quick-entry.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/quick-entry.err.log</string>
</dict>
</plist>
PLIST

if [[ "${QUICK_ENTRY_SKIP_LAUNCHCTL:-0}" != "1" ]]; then
  launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
  launchctl kickstart -k "gui/$(id -u)/$BUNDLE_ID" >/dev/null 2>&1 || true
fi

echo "Installed $INSTALLED_APP"
echo "Installed launch agent $LAUNCH_AGENT"
echo "Hotkey: Ctrl+Space"
echo "Captures append to $TODO_FILE under ## Inbox"
