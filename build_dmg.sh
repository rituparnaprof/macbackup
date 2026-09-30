#!/bin/bash
#
#  build_dmg.sh
#  MacBackup
#
#  Copyright (C) 2024-2026 MacBackup Contributors
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program.  If not, see <https://www.gnu.org/licenses/>.
#

# Exit on error
set -e

APP_NAME="MacBackup"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"
DMG_NAME="$APP_NAME.dmg"
ICON_PNG="AppIcon.png"
ICON_ICNS="MacBackup.icns"

echo "🎨 Generating App Icon..."
if [ -f "$ICON_PNG" ]; then
    mkdir -p "$APP_NAME.iconset"
    sips -s format png -z 16 16     "$ICON_PNG" --out "$APP_NAME.iconset/icon_16x16.png"
    sips -s format png -z 32 32     "$ICON_PNG" --out "$APP_NAME.iconset/icon_16x16@2x.png"
    sips -s format png -z 32 32     "$ICON_PNG" --out "$APP_NAME.iconset/icon_32x32.png"
    sips -s format png -z 64 64     "$ICON_PNG" --out "$APP_NAME.iconset/icon_32x32@2x.png"
    sips -s format png -z 128 128   "$ICON_PNG" --out "$APP_NAME.iconset/icon_128x128.png"
    sips -s format png -z 256 256   "$ICON_PNG" --out "$APP_NAME.iconset/icon_128x128@2x.png"
    sips -s format png -z 256 256   "$ICON_PNG" --out "$APP_NAME.iconset/icon_256x256.png"
    sips -s format png -z 512 512   "$ICON_PNG" --out "$APP_NAME.iconset/icon_256x256@2x.png"
    sips -s format png -z 512 512   "$ICON_PNG" --out "$APP_NAME.iconset/icon_512x512.png"
    sips -s format png -z 1024 1024 "$ICON_PNG" --out "$APP_NAME.iconset/icon_512x512@2x.png"
    iconutil -c icns "$APP_NAME.iconset"
    rm -rf "$APP_NAME.iconset"
else
    echo "⚠️  Warning: $ICON_PNG not found. Skipping icon generation."
fi

echo "🔨 Building $APP_NAME in Release mode..."
swift build -c release

echo "📦 Creating App Bundle structure..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

echo "🚀 Copying binary..."
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

if [ -f "$ICON_ICNS" ]; then
    echo "🖼️  Copying icon..."
    cp "$ICON_ICNS" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

echo "📄 Creating Info.plist..."
cat <<EOF > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.user.MacBackup</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>MacBackup</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>macbackup</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

echo "💿 Creating DMG image..."
rm -f "$DMG_NAME"
# Create a temporary folder for the DMG content
DMG_TEMP="dmg_temp"
rm -rf "$DMG_TEMP"
mkdir -p "$DMG_TEMP"
cp -R "$APP_BUNDLE" "$DMG_TEMP/"
ln -s /Applications "$DMG_TEMP/Applications"

hdiutil create -volname "$APP_NAME Installer" -srcfolder "$DMG_TEMP" -ov -format UDZO "$DMG_NAME"

echo "✨ Cleaning up..."
rm -rf "$APP_BUNDLE"
rm -rf "$DMG_TEMP"

echo "✅ Build Complete! $DMG_NAME has been created."
