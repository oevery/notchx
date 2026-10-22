#!/bin/bash
# Xcode resource phase: a small native helper, with no additional app host.
set -euo pipefail
: "${SRCROOT:?}"
: "${TARGET_BUILD_DIR:?}"
: "${TARGET_TEMP_DIR:?}"
destination="$TARGET_BUILD_DIR/NotchX.app/Contents/Helpers"
mkdir -p "$destination"
sdk=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
products=()
for architecture in ${ARCHS:-$(/usr/bin/uname -m)}; do
  case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported helper architecture" >&2; exit 1 ;; esac
  product="$TARGET_TEMP_DIR/NotchXAgentBridge-$architecture"
  /usr/bin/xcrun swiftc -swift-version 5 -O -sdk "$sdk" -target "$architecture-apple-macosx26.0" \
    "$SRCROOT/App/Modules/Agent/AgentHookWire.swift" \
    "$SRCROOT/App/Modules/Agent/AgentUnixSocket.swift" \
    "$SRCROOT/App/Modules/Agent/CodexHookMetadata.swift" \
    "$SRCROOT/Helpers/NotchXAgentBridge/main.swift" -o "$product"
  products+=("$product")
done
/usr/bin/lipo -create "${products[@]}" -output "$destination/NotchXAgentBridge"
chmod 755 "$destination/NotchXAgentBridge"

# This is nested code in Contents/Helpers. Sign the final universal executable
# before Xcode signs the containing app; signing individual slices before lipo
# would not cover the embedded result. Keep unsigned developer builds unsigned.
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES ]]; then
  identity="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
  signing_arguments=(--force --sign "$identity" --identifier app.notchx.agent-bridge)
  if [[ "$identity" == - ]]; then
    signing_arguments+=(--timestamp=none)
  elif [[ "${ENABLE_HARDENED_RUNTIME:-NO}" == YES ]]; then
    signing_arguments+=(--options runtime)
  fi
  /usr/bin/codesign "${signing_arguments[@]}" "$destination/NotchXAgentBridge"
  /usr/bin/codesign --verify --strict "$destination/NotchXAgentBridge"
fi
