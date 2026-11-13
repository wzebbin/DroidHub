#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?Provide the output directory}"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
NDK="${ANDROID_NDK_HOME:-$SDK/ndk/28.2.13676358}"
TOOLS="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"
if [ ! -x "$TOOLS/aarch64-linux-android24-clang" ]; then
    echo "Android NDK 28.2.13676358 is required. Set ANDROID_NDK_HOME to use another installed NDK." >&2
    exit 1
fi
mkdir -p "$OUT"
while read -r abi target; do
    "$TOOLS/$target-clang" -Wall -Wextra -Werror -Os -fPIE -pie -s "$ROOT/macOS/Helpers/remote-move.c" -o "$OUT/$abi"
done <<'EOF'
arm64-v8a aarch64-linux-android24
armeabi-v7a armv7a-linux-androideabi24
x86_64 x86_64-linux-android24
x86 i686-linux-android24
EOF
