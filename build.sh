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

# 3. Create app bundle structure (clean first so stale files never linger between builds)
echo "Creating App Bundle..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# 4. Copy binary and resources
# Note: universal binaries are output to .build/apple/Products/Release/Tabby
cp "$BUILD_DIR/Tabby" "$MACOS_DIR/"
cp "Resources/Info.plist" "$APP_DIR/Contents/"
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$RESOURCES_DIR/"
fi
chmod +x "$MACOS_DIR/Tabby"

# 4b. Embed Sparkle.framework (auto-update). ditto preserves the Versions/Current symlinks.
FRAMEWORKS_DIR="$APP_DIR/Contents/Frameworks"
SPARKLE_SRC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
mkdir -p "$FRAMEWORKS_DIR"
ditto "$SPARKLE_SRC" "$FRAMEWORKS_DIR/Sparkle.framework"
# Let the executable find the framework at runtime (its install name is @rpath/Sparkle.framework/...)
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/Tabby" 2>/dev/null || true

# 5. Sign inside-out with hardened runtime (required for notarization), app bundle last.
# Prefer a "Developer ID Application" cert (required to distribute + notarize); fall back to any.
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | head -1 | sed 's/.*"\(.*\)"/\1/')
    [ -n "$SIGN_IDENTITY" ] && echo "NOTE: No 'Developer ID Application' cert found — using a dev cert. Fine for local runs, but you CANNOT notarize/distribute with it."
fi
if [ -n "$SIGN_IDENTITY" ] && [ "$SIGN_IDENTITY" != "0 valid identities found" ]; then
    echo "Signing with: $SIGN_IDENTITY"
    RUNTIME="--options runtime --timestamp"
else
    echo "No developer identity found. Falling back to ad-hoc signing."
    echo "WARNING: Ad-hoc signing is not suitable for distribution or notarization!"
    SIGN_IDENTITY="-"
    RUNTIME=""   # ad-hoc can't use hardened runtime / secure timestamp
fi

FW="$FRAMEWORKS_DIR/Sparkle.framework/Versions/B"
# XPC services are sandboxed — keep their embedded entitlements.
codesign --force $RUNTIME --preserve-metadata=entitlements --sign "$SIGN_IDENTITY" "$FW/XPCServices/Installer.xpc"
codesign --force $RUNTIME --preserve-metadata=entitlements --sign "$SIGN_IDENTITY" "$FW/XPCServices/Downloader.xpc"
codesign --force $RUNTIME --sign "$SIGN_IDENTITY" "$FW/Autoupdate"
codesign --force $RUNTIME --sign "$SIGN_IDENTITY" "$FW/Updater.app"
codesign --force $RUNTIME --sign "$SIGN_IDENTITY" "$FRAMEWORKS_DIR/Sparkle.framework"
# App last, with its own entitlements. No --deep: nested code is already signed above.
codesign --force $RUNTIME --entitlements "Resources/Tabby.entitlements" --sign "$SIGN_IDENTITY" "$APP_DIR"

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
