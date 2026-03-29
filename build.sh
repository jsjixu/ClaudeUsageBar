#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="Claude Usage Bar"
APP_BUNDLE="${APP_NAME}.app"
BINARY_NAME="ClaudeUsageBar"

echo "Building ${APP_NAME}..."

# Compile
swiftc -o "$BINARY_NAME" \
  -target arm64-apple-macosx15.0 \
  -framework AppKit \
  -framework SwiftUI \
  -framework Security \
  -Osize \
  -parse-as-library \
  Sources/UsageModel.swift \
  Sources/OAuthManager.swift \
  Sources/UsageAPI.swift \
  Sources/PopoverView.swift \
  Sources/AppDelegate.swift \
  Sources/main.swift

echo "✅ Binary compiled"

# Create .app bundle
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/"
cp Info.plist "$APP_BUNDLE/Contents/"
cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/"

# Ad-hoc code sign
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || echo "⚠️  Code signing skipped"

echo "✅ Built: ./${APP_BUNDLE}"
echo "   Run: open './${APP_BUNDLE}'"
echo "   Install: cp -r './${APP_BUNDLE}' /Applications/"
