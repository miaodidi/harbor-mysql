#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIGURATION="${CONFIGURATION:-release}"
swift build -c "$CONFIGURATION" --product Harbor
HARBOR_BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
HARBOR_DIST_DIR="${HARBOR_DIST_DIR:-$PWD/dist}"
HARBOR_APP="$HARBOR_DIST_DIR/Harbor.app"
mkdir -p "$HARBOR_APP/Contents/MacOS" "$HARBOR_APP/Contents/Resources"
cp "$HARBOR_BIN_DIR/Harbor" "$HARBOR_APP/Contents/MacOS/Harbor"
# Newer Swift toolchains can emit back-deployment dylibs. Bundle them so Xcode is
# not required on the receiving Mac (e.g. libswiftCompatibilitySpan.dylib).
mkdir -p "$HARBOR_APP/Contents/Frameworks"
xcrun swift-stdlib-tool --copy --scan-executable "$HARBOR_APP/Contents/MacOS/Harbor" --platform macosx --destination "$HARBOR_APP/Contents/Frameworks"
install_name_tool -add_rpath @executable_path/../Frameworks "$HARBOR_APP/Contents/MacOS/Harbor"
cp Resources/Info.plist "$HARBOR_APP/Contents/Info.plist"
if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make-icon.swift .build/Harbor.iconset
  iconutil -c icns .build/Harbor.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$HARBOR_APP/Contents/Resources/"
cp LICENSE THIRD_PARTY_NOTICES.md "$HARBOR_APP/Contents/Resources/"
shopt -s nullglob
for bundle in "$HARBOR_BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$HARBOR_APP/Contents/Resources/"
done
codesign --force --deep --sign "${HARBOR_SIGN_IDENTITY:--}" "$HARBOR_APP"
codesign --verify --deep --strict "$HARBOR_APP"
ditto -c -k --keepParent "$HARBOR_APP" "$HARBOR_DIST_DIR/Harbor-$(uname -m).zip"
printf 'Built: %s\n' "$HARBOR_APP"
