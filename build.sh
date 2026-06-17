#!/bin/bash
set -e

echo "=== Building Tabby ==="

# 1. Clean and build using SPM (Universal Binary for Intel & Apple Silicon)
echo "Compiling Universal Binary (arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64

# 2. Define build directory variables
BUILD_DIR=".build/apple/Products/Release"
APP_DIR="build/Tabby.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
BUNDLE_ID="com.tabby.switcher"

# 3. Create app bundle structure
echo "Creating App Bundle..."
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# 4. Copy binary and resources
# Note: universal binaries are output to .build/apple/Products/Release/Tabby
cp "$BUILD_DIR/Tabby" "$MACOS_DIR/"
cp "Resources/Info.plist" "$APP_DIR/Contents/"
cp "Resources/Tabby.entitlements" "$APP_DIR/Contents/"
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$RESOURCES_DIR/"
fi
chmod +x "$MACOS_DIR/Tabby"

# 5. Sign the app bundle with a real developer identity (stable signature)
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | head -1 | sed 's/.*"\(.*\)"/\1/')
if [ -n "$SIGN_IDENTITY" ] && [ "$SIGN_IDENTITY" != "0 valid identities found" ]; then
    echo "Signing App Bundle with: $SIGN_IDENTITY"
    codesign --force --deep --sign "$SIGN_IDENTITY" \
        --entitlements "Resources/Tabby.entitlements" \
        "$APP_DIR"
else
    echo "No developer identity found. Falling back to ad-hoc signing."
    echo "WARNING: Ad-hoc signing is not suitable for widespread distribution!"
    codesign --force --deep --sign - \
        --entitlements "Resources/Tabby.entitlements" \
        "$APP_DIR"
fi

# 6. Create Production DMG Disk Image
echo "Packaging into Production DMG..."
rm -rf build/dmg_root
mkdir -p build/dmg_root
cp -R "$APP_DIR" build/dmg_root/
ln -s /Applications build/dmg_root/Applications
rm -f build/Tabby.dmg
hdiutil create -volname "Tabby" -srcfolder build/dmg_root -ov -format UDZO build/Tabby.dmg

echo "=== Tabby successfully packaged for Production! ==="
echo "You can find the standalone app at:"
echo "  $(pwd)/$APP_DIR"
echo ""
echo "You can find the distributable DMG at:"
echo "  $(pwd)/build/Tabby.dmg"
echo ""
echo "To stop the running application, run: pkill -f Tabby"
echo "======================================"
