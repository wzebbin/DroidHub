#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "${1-}" in
    ""|--release) ;;
    *) echo "Usage: $0 [--release]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [--release]" >&2
    exit 2
fi
bash "$ROOT/scripts/swift-macos.sh" build -c release
BIN_DIR="$(bash "$ROOT/scripts/swift-macos.sh" build -c release --show-bin-path)"
APP="$ROOT/dist/DroidHub.app"
ARCH="$(lipo -archs "$BIN_DIR/DroidHub")"
case "$ARCH" in
    arm64)
        SCRCPY_ARCH=aarch64
        SCRCPY_SHA=33611e51977a8289e2e124b220f727895181ef2eb9060e0987a4dc2db9cf0d6b
        ;;
    x86_64)
        SCRCPY_ARCH=x86_64
        SCRCPY_SHA=31a5467a9e907f162b093267cbbab1276b15c6e709c2ea8159566a8d165beb50
        ;;
    *)
        echo "Build one macOS architecture at a time (arm64 or x86_64)." >&2
        exit 1
        ;;
esac

CACHE="$ROOT/.build/bundled-tools"
mkdir -p "$CACHE" "$ROOT/dist"
STAGING="$(mktemp -d "$ROOT/dist/.droidhub-build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

fetch_archive() {
    local name="$1" url="$2" expected="$3"
    local archive="$CACHE/$name"
    local download="$STAGING/$name"
    if ! printf '%s  %s\n' "$expected" "$archive" | shasum -a 256 -c -s - 2>/dev/null; then
        curl --fail --location --silent --show-error --retry 2 --max-time 120 --output "$download" "$url"
        printf '%s  %s\n' "$expected" "$download" | shasum -a 256 -c -
        mv -f "$download" "$archive"
    fi
}

SCRCPY_VERSION=5.0.1
SCRCPY_PACKAGE="scrcpy-macos-${SCRCPY_ARCH}-v${SCRCPY_VERSION}"
PLATFORM_TOOLS_PACKAGE="platform-tools_r37.0.1-darwin.zip"
fetch_archive "$SCRCPY_PACKAGE.tar.gz" \
    "https://github.com/Genymobile/scrcpy/releases/download/v$SCRCPY_VERSION/$SCRCPY_PACKAGE.tar.gz" "$SCRCPY_SHA"
fetch_archive "$PLATFORM_TOOLS_PACKAGE" \
    "https://dl.google.com/android/repository/$PLATFORM_TOOLS_PACKAGE" \
    ee39ad5967e95c2a07f04dbcbde96b1a0c916ba376096db5d2f498b7727a5d1d

PRODUCT="$STAGING/DroidHub.app"
HELPERS="$PRODUCT/Contents/Helpers"
SCRCPY_RESOURCES="$PRODUCT/Contents/Resources/scrcpy"
NOTICES="$PRODUCT/Contents/Resources/ThirdPartyNotices"
mkdir -p "$PRODUCT/Contents/MacOS" "$HELPERS" "$SCRCPY_RESOURCES" "$NOTICES"
cp "$BIN_DIR/DroidHub" "$PRODUCT/Contents/MacOS/DroidHub"
ditto "$BIN_DIR/DroidHub_DroidHubCore.bundle" "$PRODUCT/Contents/Resources/DroidHub_DroidHubCore.bundle"
cp "$ROOT/macOS/Info.plist" "$PRODUCT/Contents/Info.plist"
ICONSET="$STAGING/DroidHub.iconset"
ICON_SOURCE="$ROOT/macOS/Resources/DroidHub-Bright.png"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns -o "$PRODUCT/Contents/Resources/DroidHub.icns" "$ICONSET"
bash "$ROOT/scripts/build-android-move.sh" "$PRODUCT/Contents/Resources/android-move"
bash "$ROOT/scripts/build-android-app-metadata.sh" "$PRODUCT/Contents/Resources/android-app-metadata.jar"

unzip -p "$CACHE/$PLATFORM_TOOLS_PACKAGE" platform-tools/adb > "$STAGING/adb"
lipo "$STAGING/adb" -thin "$ARCH" -output "$HELPERS/adb"
unzip -p "$CACHE/$PLATFORM_TOOLS_PACKAGE" platform-tools/NOTICE.txt > "$NOTICES/ADB-NOTICE.txt"
tar -xOzf "$CACHE/$SCRCPY_PACKAGE.tar.gz" "$SCRCPY_PACKAGE/scrcpy" > "$HELPERS/scrcpy"
for resource in scrcpy-server scrcpy.png disconnected.png; do
    tar -xOzf "$CACHE/$SCRCPY_PACKAGE.tar.gz" "$SCRCPY_PACKAGE/$resource" > "$SCRCPY_RESOURCES/$resource"
done
tar -xOzf "$CACHE/$SCRCPY_PACKAGE.tar.gz" "$SCRCPY_PACKAGE/LICENSE" > "$NOTICES/scrcpy-LICENSE.txt"
cp "$ROOT/licenses/"*.txt "$NOTICES/"
cp "$ROOT/licenses/README.md" "$NOTICES/ThirdPartyNotices.md"

chmod 755 "$HELPERS/adb" "$HELPERS/scrcpy"
codesign --force --sign - "$HELPERS/adb"
codesign --force --sign - "$HELPERS/scrcpy"
codesign --force --sign - "$PRODUCT"
codesign --verify --deep --strict "$PRODUCT"

if [ "${1-}" = --release ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PRODUCT/Contents/Info.plist")"
    ARCHIVE="DroidHub-${VERSION}-macOS-${ARCH}.zip"
    ditto -c -k --sequesterRsrc --keepParent "$PRODUCT" "$STAGING/$ARCHIVE"
    (cd "$STAGING" && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
fi

if [ -e "$APP" ]; then
    mv "$APP" "$STAGING/previous.app"
fi
if ! mv "$PRODUCT" "$APP"; then
    if [ -e "$STAGING/previous.app" ]; then
        mv "$STAGING/previous.app" "$APP"
    fi
    exit 1
fi
echo "Built $APP"
if [ "${1-}" = --release ]; then
    mv -f "$STAGING/$ARCHIVE" "$STAGING/$ARCHIVE.sha256" "$ROOT/dist/"
    echo "Built $ROOT/dist/$ARCHIVE and $ARCHIVE.sha256"
fi
