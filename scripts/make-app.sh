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
    <!-- CFBundleVersion is required for LaunchServices/UNUserNotificationCenter to
         register the bundle; without it the app never appears in Notifications
         settings and requestAuthorization returns "not allowed". -->
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Debrief records your side of interview calls to transcribe and coach you.</string>
</dict></plist>
PLIST
# Sign with a STABLE identity so macOS TCC (mic/Screen Recording) and Keychain
# grants survive rebuilds. Ad-hoc (`--sign -`) re-keys the app's designated
# requirement to a fresh cdhash every build, so the OS treats each rebuild as a
# new, untrusted app and drops every prior grant. A self-signed code-signing
# cert ties the requirement to the cert instead of the binary. Override the name
# with DEBRIEF_SIGN_IDENTITY. Create one once (Keychain Access > Certificate
# Assistant > Create a Certificate: Self Signed Root, type Code Signing).
# Note: no `-v` (valid-only) here — a self-signed root is untrusted
# (CSSMERR_TP_NOT_TRUSTED) so `-v` hides it, yet codesign signs with it fine and
# the resulting designated requirement is cert-based (stable across rebuilds),
# which is all TCC/Keychain need. Trust is not required.
IDENTITY="${DEBRIEF_SIGN_IDENTITY:-Debrief Local Signing}"
if security find-identity -p codesigning | grep -qF "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Built $APP — signed with stable identity: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "WARNING: no '$IDENTITY' code-signing identity found — fell back to ad-hoc."
    echo "  TCC (mic/Screen Recording) and Keychain grants will NOT persist across rebuilds."
    echo "  Fix once: Keychain Access > Certificate Assistant > Create a Certificate"
    echo "    Name: $IDENTITY | Identity Type: Self Signed Root | Certificate Type: Code Signing"
fi
echo "Launch with: open $APP"
