#!/bin/zsh
# Assembles a runnable PersonalAgent.app from the release build. Ad-hoc signed: fine for
# your own machine; for distribution, sign with a Developer ID and notarize instead.
set -e
cd "$(dirname "$0")/.."

APP_NAME="PersonalAgent"
BUNDLE_ID="com.sam.personal-agent"
OUT=".build/app"
APP="$OUT/$APP_NAME.app"

echo "==> swift build -c release"
swift build -c release --product PAApp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/PAApp "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>个人助理</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>CFBundleShortVersionString</key><string>0.0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- Endpoints are user-configured: local proxies and self-hosted servers are usually
         plain http. Loads are only ever made to the URL the user typed in settings. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

SIZE=$(du -sh "$APP" | cut -f1)
echo "==> Built $APP ($SIZE)"
