#!/bin/bash
set -euo pipefail

# Build a local, sandboxed Appearance edition without publishing or installing it.
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
xcodebuild -project Open-Yoink.xcodeproj -scheme OpenYoink \
    -destination 'platform=macOS' -derivedDataPath .build/DerivedData \
    -configuration Release ENABLE_CODE_COVERAGE=NO build

TASK_OUTPUT="$TASK_ROOT/export/OpenYoink-Appearance.app"
if [ -e "$TASK_OUTPUT" ]; then
    mv "$TASK_OUTPUT" "$TASK_ROOT/export/OpenYoink-Appearance-$(date +%Y%m%d-%H%M%S).app"
fi
mkdir -p "$TASK_ROOT/export"
ditto .build/DerivedData/Build/Products/Release/OpenYoink.app "$TASK_OUTPUT"

# Match upstream make-release.sh's ad-hoc flow: leaf-first, preserving each
# component's own entitlements. Hardened Runtime cannot validate Team IDs on
# an ad-hoc app; never propagate the main app's sandbox to Sparkle helpers.
TASK_SPARKLE="$TASK_OUTPUT/Contents/Frameworks/Sparkle.framework/Versions/Current"
for TASK_COMPONENT in \
    "$TASK_SPARKLE/XPCServices/Installer.xpc" \
    "$TASK_SPARKLE/XPCServices/Downloader.xpc" \
    "$TASK_SPARKLE/Autoupdate" \
    "$TASK_SPARKLE/Updater.app" \
    "$TASK_OUTPUT/Contents/Frameworks/Sparkle.framework" \
    "$TASK_OUTPUT"; do
    codesign --force --sign - --preserve-metadata=identifier,entitlements "$TASK_COMPONENT"
done
codesign --verify --deep --strict "$TASK_OUTPUT"
echo "Local app: $TASK_OUTPUT"
