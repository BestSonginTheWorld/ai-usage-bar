#!/usr/bin/env bash
set -euo pipefail

APP_SUPPORT_DIR="$HOME/Library/Application Support/AIUsageMenuBar"
USER_APP_BUNDLE_PATH="$HOME/Applications/AIUsageMenuBar.app"
SYSTEM_APP_BUNDLE_PATH="/Applications/AIUsageMenuBar.app"
PLIST_PATH="$HOME/Library/LaunchAgents/local.ai-usage-menubar-app.plist"
LABEL="local.ai-usage-menubar-app"
GUI_DOMAIN="gui/$(id -u)"
OLD_XBAR_PLUGIN_PATH="$HOME/Library/Application Support/xbar/plugins/ai_usage.5m.py"
OLD_PLIST_PATH="$HOME/Library/LaunchAgents/local.ai-usage-refresh.plist"
OLD_LABEL="local.ai-usage-refresh"

launchctl bootout "$GUI_DOMAIN" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootout "$GUI_DOMAIN" "$OLD_PLIST_PATH" >/dev/null 2>&1 || true
launchctl disable "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1 || true
launchctl disable "$GUI_DOMAIN/$OLD_LABEL" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"
rm -f "$OLD_PLIST_PATH"
rm -f "$OLD_XBAR_PLUGIN_PATH"
rm -rf "$USER_APP_BUNDLE_PATH"
rm -rf "$SYSTEM_APP_BUNDLE_PATH"

echo "Removed app bundle and LaunchAgents."
echo "App data left intact at: $APP_SUPPORT_DIR"
echo "Delete it manually if you want a full reset."
