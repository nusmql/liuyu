#!/bin/bash
set -euo pipefail

APP_NAME="Liuyu.app"
BUNDLE_DIR="build/${APP_NAME}"

echo "Building release with Xcode..."
xcodebuild -scheme Liuyu -configuration Release -derivedDataPath .build clean build 2>&1 | tail -30

echo "Creating app bundle..."
rm -rf "build/${APP_NAME}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

BINARY_PATH=".build/Build/Products/Release/Liuyu"
if [ -f "${BINARY_PATH}" ]; then
    cp "${BINARY_PATH}" "${BUNDLE_DIR}/Contents/MacOS/"
else
    echo "Error: Binary not found at ${BINARY_PATH}"
    exit 1
fi

cp "Sources/LiuyuLib/Resources/Info.plist" "${BUNDLE_DIR}/Contents/"
cp "Sources/LiuyuLib/Resources/AppIcon.icns" "${BUNDLE_DIR}/Contents/Resources/"
cp "Sources/LiuyuLib/Resources/MenuIcon_18.png" "${BUNDLE_DIR}/Contents/Resources/"
cp "Sources/LiuyuLib/Resources/MenuIcon_18@2x.png" "${BUNDLE_DIR}/Contents/Resources/"

LUCIDE_BUNDLE=".build/Build/Products/Release/LucideIcons_LucideIcons.bundle"
if [ -d "${LUCIDE_BUNDLE}" ]; then
    echo "Copying LucideIcons resources..."
    cp -R "${LUCIDE_BUNDLE}" "${BUNDLE_DIR}/Contents/Resources/"
fi

echo "Signing app bundle..."
if security find-identity -v -p codesigning | grep -q "Liuyu Dev"; then
    codesign --force --sign "Liuyu Dev" --entitlements "Sources/LiuyuLib/Resources/Liuyu.entitlements" --identifier "com.liuyu.app" "${BUNDLE_DIR}"
else
    echo "Note: Using ad-hoc signing (no 'Liuyu Dev' certificate found)"
    codesign --force --sign - --entitlements "Sources/LiuyuLib/Resources/Liuyu.entitlements" --identifier "com.liuyu.app" "${BUNDLE_DIR}"
fi

echo "App bundle created at build/${APP_NAME}"
echo "Run with: open build/${APP_NAME}"
