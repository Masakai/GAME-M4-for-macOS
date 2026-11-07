#!/bin/bash
# GAME-M4.app を dist/ に作る。署名は ad-hoc(開発者 ID なし)で、公証はしない(設計書 M14)。
# 使い方: Tools/build_app.sh
# ビルドの作業領域は Dropbox の外(~/Library/Caches/GAME-M4/build)に置く(設計書 M13)。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${GAMEM4_VERSION:-0.1.0}"
SCRATCH="$HOME/Library/Caches/GAME-M4/build"
APP="dist/GAME-M4.app"

swift build -c release --scratch-path "$SCRATCH" --product GameM4App
swift build -c release --scratch-path "$SCRATCH" --product gamem4
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/GameM4App" "$APP/Contents/MacOS/GameM4App"
# CLI も同梱する(Contents/MacOS/gamem4)
cp "$BIN/gamem4" "$APP/Contents/MacOS/gamem4"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>GAME-M4</string>
    <key>CFBundleDisplayName</key><string>GAME-M4</string>
    <key>CFBundleIdentifier</key><string>local.riverruns.game-m4</string>
    <key>CFBundleDevelopmentRegion</key><string>ja</string>
    <key>CFBundleExecutable</key><string>GameM4App</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSArchitecturePriority</key><array><string>arm64</string></array>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>GAME Program</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>CFBundleTypeExtensions</key><array><string>gam</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/MacOS/gamem4"
codesign --force --sign - "$APP"
echo "作成した: $APP"
