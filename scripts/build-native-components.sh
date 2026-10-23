#!/bin/bash
# Xcode 构建阶段：组装资源与原生辅助程序，保留框架链接和权限。
set -euo pipefail
: "${SRCROOT:?Run from Xcode or python3 scripts/release.py build}"
: "${TARGET_BUILD_DIR:?}"
: "${BUILT_PRODUCTS_DIR:?}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
[[ "$resources" == */NotchX.app/Contents/Resources ]] || {
  echo "Unexpected native app resource destination: $resources" >&2; exit 1;
}
# Remove only this target's generated resource directory so deleted native assets
# cannot linger across incremental builds.
rm -rf -- "$resources"
mkdir -p "$resources"
/usr/bin/ditto "$SRCROOT/App/Resources" "$resources"
cp "$SRCROOT/Config/MediaRemoteAdapter.json" "$resources/MediaRemoteAdapter/Provenance.json"
# The adapter is loaded at runtime, not linked as a public framework.
# Keep its original signed payload and executable permissions intact.
test -x "$resources/MediaRemoteAdapter/mediaremote-adapter.pl"
test -x "$resources/MediaRemoteAdapter/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter"
test -L "$resources/MediaRemoteAdapter/MediaRemoteAdapter.framework/Versions/Current"
cp "$SRCROOT/THIRD_PARTY_NOTICES.md" "$resources/THIRD_PARTY_NOTICES.md"

/usr/bin/ditto "$SRCROOT/Licenses" "$resources/Licenses"
destination="$TARGET_BUILD_DIR/NotchX.app/Contents/Helpers"
mkdir -p "$destination"
test -x "$BUILT_PRODUCTS_DIR/NotchXAgentBridge"
/usr/bin/ditto "$BUILT_PRODUCTS_DIR/NotchXAgentBridge" "$destination/NotchXAgentBridge"
chmod 755 "$destination/NotchXAgentBridge"

# This is nested code in Contents/Helpers. Sign the final target executable
# before Xcode signs the containing app. Keep unsigned developer builds unsigned.
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
