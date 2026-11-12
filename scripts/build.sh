#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Set UNIVERSAL=1 for both Apple Silicon and Intel. The default builds this Mac's architecture.
# Set CODE_SIGN_IDENTITY to a local signing identity for a stable microphone permission.
# No certificates, passwords, or provisioning profiles belong in this repository.
app="$PWD/dist/AudioRelay Bridge.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    for arch in arm64 x86_64; do
        swift build --build-system native -c release --triple "${arch}-apple-macosx13.0"
    done
    arm_bin="$(swift build --build-system native -c release --triple arm64-apple-macosx13.0 --show-bin-path)/AudioRelayBridge"
    intel_bin="$(swift build --build-system native -c release --triple x86_64-apple-macosx13.0 --show-bin-path)/AudioRelayBridge"
    lipo -create "$arm_bin" "$intel_bin" -output "$app/Contents/MacOS/AudioRelayBridge"
else
    swift build --build-system native -c release
    bin="$(swift build --build-system native -c release --show-bin-path)/AudioRelayBridge"
    cp "$bin" "$app/Contents/MacOS/AudioRelayBridge"
fi
cp Resources/Info.plist "$app/Contents/Info.plist"
swift scripts/make-icon.swift "$PWD/dist/AppIcon.iconset"
iconutil -c icns "$PWD/dist/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
identity="${CODE_SIGN_IDENTITY:--}"
if [[ "$identity" == "-" ]]; then
    codesign --force --sign - --entitlements Resources/AudioRelayBridge.entitlements "$app"
else
    codesign --force --options runtime --timestamp --sign "$identity" --entitlements Resources/AudioRelayBridge.entitlements "$app"
fi
codesign --verify --deep --strict "$app"
printf '\nBuilt %s\n' "$app"
