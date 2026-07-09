#!/bin/bash
# Bundle the SPM executable into Debrief.app so macOS TCC prompts (mic/screen)
# attach to Debrief instead of the launching terminal.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build -c release
APP=Debrief.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DebriefApp "$APP/Contents/MacOS/Debrief"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>Debrief</string>
    <key>CFBundleIdentifier</key><string>com.debrief.app</string>
    <key>CFBundleName</key><string>Debrief</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Debrief records your side of interview calls to transcribe and coach you.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Built $APP — launch with: open $APP"
