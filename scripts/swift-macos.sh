#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMAND="$1"
shift
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
exec swift "$COMMAND" --package-path "$ROOT/macOS" --scratch-path "$ROOT/.build/swift" \
    --cache-path "$ROOT/.build/swift-cache" --config-path "$ROOT/.build/swift-config" \
    --security-path "$ROOT/.build/swift-security" --disable-sandbox "$@"
