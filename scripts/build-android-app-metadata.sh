#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?Provide the output jar}"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
ANDROID_JAR="$SDK/platforms/android-34/android.jar"
D8="$SDK/build-tools/36.0.0/d8"
if [ ! -f "$ANDROID_JAR" ] || [ ! -x "$D8" ]; then
    echo "Android SDK Platform 34 and Build Tools 36.0.0 are required." >&2
    exit 1
fi

if [ -z "${JAVA_HOME:-}" ]; then
    JAVA_HOME="$(/usr/libexec/java_home -v '17+' 2>/dev/null || true)"
    if [ -z "$JAVA_HOME" ]; then
        for candidate in /opt/homebrew/opt/openjdk /usr/local/opt/openjdk; do
            if [ -x "$candidate/bin/javac" ]; then JAVA_HOME="$candidate"; break; fi
        done
    fi
fi
if [ ! -x "${JAVA_HOME:-}/bin/javac" ]; then
    echo "Set JAVA_HOME to a JDK 17 or newer to build the Android app metadata helper." >&2
    exit 1
fi
export JAVA_HOME

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$(dirname "$OUT")"
"$JAVA_HOME/bin/javac" --release 8 -Xlint:-options -classpath "$ANDROID_JAR" -d "$WORK" "$ROOT/macOS/Helpers/AppMetadata.java"
"$D8" --lib "$ANDROID_JAR" --min-api 24 --output "$OUT" "$WORK/AppMetadata.class"
