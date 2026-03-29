#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_BUNDLE="Claude Usage Bar.app"
INSTALL_DIR="/Applications"
PLIST_NAME="com.openclaw.claude-usage-bar"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"

# Build first
./build.sh

# Kill existing instance
pkill -f "ClaudeUsageBar" 2>/dev/null || true
sleep 1

# Install .app bundle
cp -rf "$APP_BUNDLE" "$INSTALL_DIR/"
echo "✅ Installed to $INSTALL_DIR/$APP_BUNDLE"

# Create LaunchAgent
cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>${INSTALL_DIR}/${APP_BUNDLE}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

# Load LaunchAgent
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

# Launch now
open "$INSTALL_DIR/$APP_BUNDLE"

echo "✅ LaunchAgent installed and loaded: $PLIST_NAME"
echo "   App installed at: $INSTALL_DIR/$APP_BUNDLE"
echo "   Will start automatically on login."
echo "   To stop: launchctl unload $PLIST_PATH"
