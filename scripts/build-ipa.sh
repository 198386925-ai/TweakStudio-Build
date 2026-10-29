#!/bin/bash
# Build unsigned TweakStudio IPA from repository source (macOS runner).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP_NAME=TweakStudio

# Restore binary icon stored base64-encoded (MCP transport is text-only).
ICON_B64="TweakStudio/Assets.xcassets/AppIcon.appiconset/Icon-1024.png.b64"
ICON_PNG="TweakStudio/Assets.xcassets/AppIcon.appiconset/Icon-1024.png"
if [ -f "$ICON_B64" ]; then
  python3 -c "import base64,sys; sys.stdout.buffer.write(base64.b64decode(open(sys.argv[1]).read()))" "$ICON_B64" > "$ICON_PNG"
fi

# Restore the template preference icon stored base64-encoded (same transport reason).
TPL_ICON_B64="TweakStudio/Resources/Templates/preferences/__PREFIX__Prefs/Resources/icon@2x.png.b64"
TPL_ICON_PNG="TweakStudio/Resources/Templates/preferences/__PREFIX__Prefs/Resources/icon@2x.png"
if [ -f "$TPL_ICON_B64" ]; then
  python3 -c "import base64,sys; sys.stdout.buffer.write(base64.b64decode(open(sys.argv[1]).read()))" "$TPL_ICON_B64" > "$TPL_ICON_PNG"
fi

xcodebuild -version
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
case "$SDK_VERSION" in
  26.*) ;;
  *) echo "ERROR: This workflow requires an iOS 26 SDK; found $SDK_VERSION"; exit 1 ;;
esac

mkdir -p output
xcodebuild \
  -project TweakStudio.xcodeproj \
  -scheme TweakStudio -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build

APP="build/Build/Products/Release-iphoneos/${APP_NAME}.app"
test -f "$APP/$APP_NAME"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")
BUILT_SDK=$(/usr/libexec/PlistBuddy -c 'Print :DTSDKName' "$APP/Info.plist")
case "$BUILT_SDK" in iphoneos26.*) ;; *) echo "ERROR: Incorrect built SDK: $BUILT_SDK"; exit 1 ;; esac

STAGE=$(mktemp -d "$ROOT/build/package.XXXXXX")
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
NAME="${APP_NAME}-${VERSION}-Build(${BUILD}).ipa"
(cd "$STAGE" && /usr/bin/zip -qry "$ROOT/output/$NAME" Payload)
unzip -t "output/$NAME"

# Clean source backup zip (full real source only; no build artifacts, no git metadata).
SRC_NAME="${APP_NAME}-${VERSION}-Build(${BUILD})-src.zip"
(cd "$ROOT" && /usr/bin/zip -qry "output/$SRC_NAME" . -x 'build/*' -x 'output/*' -x '.git/*' -x '.gitignore')
unzip -t "output/$SRC_NAME"

echo "IPA: output/$NAME (unsigned; sign before installation)"
echo "SRC: output/$SRC_NAME"
