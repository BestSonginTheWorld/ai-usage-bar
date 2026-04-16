#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SUPPORT_DIR="$HOME/Library/Application Support/AIUsageMenuBar"
LOG_DIR="$APP_SUPPORT_DIR/logs"
DEBUG_DIR="$APP_SUPPORT_DIR/debug"
WORKDIR_PATH="$APP_SUPPORT_DIR/workdir"
RUNTIME_DIR="$APP_SUPPORT_DIR/runtime"
CONFIG_PATH="$APP_SUPPORT_DIR/config.json"
APP_INSTALL_DIR="$HOME/Applications"
APP_BUNDLE_PATH="$APP_INSTALL_DIR/AIUsageMenuBar.app"
APP_EXECUTABLE_PATH="$APP_BUNDLE_PATH/Contents/MacOS/AIUsageMenuBarApp"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/local.ai-usage-menubar-app.plist"
LABEL="local.ai-usage-menubar-app"
GUI_DOMAIN="gui/$(id -u)"
OLD_XBAR_PLUGIN_PATH="$HOME/Library/Application Support/xbar/plugins/ai_usage.5m.py"
OLD_PLIST_PATH="$LAUNCH_AGENTS_DIR/local.ai-usage-refresh.plist"
OLD_LABEL="local.ai-usage-refresh"

mkdir -p "$APP_SUPPORT_DIR" "$LOG_DIR" "$DEBUG_DIR" "$WORKDIR_PATH" "$RUNTIME_DIR" "$LAUNCH_AGENTS_DIR" "$APP_INSTALL_DIR"

if [[ ! -f "$CONFIG_PATH" ]]; then
  cp "$ROOT_DIR/config.example.json" "$CONFIG_PATH"
  echo "Created default config: $CONFIG_PATH"
else
  echo "Keeping existing config: $CONFIG_PATH"
fi

cp "$ROOT_DIR/ai_usage_collector.py" "$RUNTIME_DIR/ai_usage_collector.py"
chmod +x "$RUNTIME_DIR/ai_usage_collector.py"

APP_BUNDLE_SRC="$("$ROOT_DIR/scripts/build_app.sh")"
rm -rf "$APP_BUNDLE_PATH"
cp -R "$APP_BUNDLE_SRC" "$APP_BUNDLE_PATH"
chmod +x "$APP_EXECUTABLE_PATH"

cat >"$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${LABEL}</string>

    <key>ProgramArguments</key>
    <array>
      <string>${APP_EXECUTABLE_PATH}</string>
    </array>

    <key>WorkingDirectory</key>
    <string>${APP_SUPPORT_DIR}</string>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>${LOG_DIR}/launchd.out.log</string>

    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/launchd.err.log</string>

    <key>EnvironmentVariables</key>
    <dict>
      <key>PATH</key>
      <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
  </dict>
</plist>
PLIST

launchctl bootout "$GUI_DOMAIN" "$OLD_PLIST_PATH" >/dev/null 2>&1 || true
rm -f "$OLD_PLIST_PATH"
rm -f "$OLD_XBAR_PLUGIN_PATH"
launchctl disable "$GUI_DOMAIN/$OLD_LABEL" >/dev/null 2>&1 || true

launchctl bootout "$GUI_DOMAIN" "$PLIST_PATH" >/dev/null 2>&1 || true
pkill -x AIUsageMenuBarApp >/dev/null 2>&1 || true
launchctl bootstrap "$GUI_DOMAIN" "$PLIST_PATH"
launchctl enable "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1 || true
launchctl kickstart -k "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1 || true

echo "Installed app bundle: $APP_BUNDLE_PATH"
echo "Installed runtime collector: $RUNTIME_DIR/ai_usage_collector.py"
echo "Installed LaunchAgent: $PLIST_PATH"
echo "Runtime directory: $APP_SUPPORT_DIR"
echo "Execution workdir: $WORKDIR_PATH"
