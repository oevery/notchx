#!/bin/bash
# Syntax and source inventory only. This does NOT typecheck, link, or run AppKit.
set -euo pipefail
cd -P "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/native-parse-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
count=0
while IFS= read -r -d '' file; do
  swiftc -frontend -parse -swift-version 5 "$file"
  count=$((count + 1))
done < <(find App Tests -name '*.swift' -type f -print0)
echo "Parsed $count native Swift files. Syntax only; macOS compilation and native XCTest execution are still required."
