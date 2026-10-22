#!/bin/bash
# Validate the whitespace-separated output of lipo -archs (portable for tests).
set -euo pipefail
reported="${1:-}"
# Split only on whitespace; disable glob expansion before the intentional split.
set -f
IFS=$' \t\n'
set -- $reported
for required in arm64 x86_64; do
  found=false
  for architecture in "$@"; do
    if [[ "$architecture" == "$required" ]]; then
      found=true
      break
    fi
  done
  if [[ "$found" != true ]]; then
    echo "Universal app is missing $required; found: ${reported:-<none>}" >&2
    exit 1
  fi
done
