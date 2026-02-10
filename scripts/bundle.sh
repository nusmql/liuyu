#!/bin/bash
set -euo pipefail

BINARY_NAME="Liuyu"
APP_NAME="Liuyu.app"
BUILD_DIR=".build/release"
BUNDLE_DIR="build/${APP_NAME}"

echo "Building release..."
swift build -c release

echo "Creating app bundle..."
rm -rf "build/${APP_NAME}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

cp "${BUILD_DIR}/${BINARY_NAME}" "${BUNDLE_DIR}/Contents/MacOS/"
cp "Sources/Liuyu/Resources/Info.plist" "${BUNDLE_DIR}/Contents/"

echo "App bundle created at build/${APP_NAME}"
echo "Run with: open build/${APP_NAME}"
