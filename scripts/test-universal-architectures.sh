#!/bin/bash
set -euo pipefail
cd -P "$(dirname "$0")/.."
for architectures in 'arm64 x86_64' 'x86_64 arm64' $'  arm64\tx86_64  '; do
  bash scripts/check-universal-architectures.sh "$architectures"
done
for architectures in 'arm64' 'x86_64' '' 'arm64e x86_64' 'arm64 x86_64h'; do
  if bash scripts/check-universal-architectures.sh "$architectures" 2>/dev/null; then
    echo "Accepted incomplete architectures: $architectures" >&2
    exit 1
  fi
done
echo "PASS: universal architecture validation accepts both slices and rejects thin, empty, and substring-only matches"
