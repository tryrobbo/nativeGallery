#!/bin/bash
set -e

APP_NAME="NativeGallery"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP_BUNDLE}/Contents/MacOS"
RESOURCES_DIR="${APP_BUNDLE}/Contents/Resources"

# Create directories
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# Copy Info.plist and icon
cp Info.plist "${APP_BUNDLE}/Contents/"
cp AppIcon.icns "${RESOURCES_DIR}/"

# Compile Swift files
echo "Compiling swift files..."
swiftc \
  -O \
  -whole-module-optimization \
  -parse-as-library \
  -framework AVKit \
  -framework AVFoundation \
  -framework CoreServices \
  -o "${MACOS_DIR}/${APP_NAME}" \
  Sources/*.swift

echo "Build complete at ${APP_BUNDLE}"
