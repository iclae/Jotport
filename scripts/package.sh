#!/bin/bash
set -euo pipefail
export MACOSX_DEPLOYMENT_TARGET=12.0
swift build -c release --arch x86_64
BIN=$(swift build -c release --arch x86_64 --show-bin-path)
APP=dist/Jotport.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/licenses"
cp "$BIN/Jotport" "$APP/Contents/MacOS/"
cp assets/AppIcon.icns "$APP/Contents/Resources/"
cp scripts/jotport.ts "$APP/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp licenses/lucide-LICENSE "$APP/Contents/Resources/licenses/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.jotport.app</string>
<key>CFBundleName</key><string>Jotport</string>
<key>CFBundleExecutable</key><string>Jotport</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Jotport 需要在已打开的 Ghostty 中创建会话标签页。</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
file "$APP/Contents/MacOS/Jotport" | tee dist/architecture.txt
xcrun vtool -show-build "$APP/Contents/MacOS/Jotport" | tee dist/deployment-target.txt
grep -q 'x86_64' dist/architecture.txt
grep -q 'minos 12.0' dist/deployment-target.txt
cp docs/testing.md dist/READ-ME-FIRST.md
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/Jotport-macOS12-Intel.app.zip
(cd dist && shasum -a 256 Jotport-macOS12-Intel.app.zip > SHA256SUMS)
