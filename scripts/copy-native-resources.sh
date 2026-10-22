#!/bin/bash
# Xcode build phase: copy the approved native assets, preserving framework links/modes.
set -euo pipefail
: "${SRCROOT:?Run from Xcode or scripts/build-app.sh}"
: "${TARGET_BUILD_DIR:?}"
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
# The adapter is loaded at runtime, not linked as a public framework.
# Keep its original signed payload and executable permissions intact.
test -x "$resources/MediaRemoteAdapter/mediaremote-adapter.pl"
test -x "$resources/MediaRemoteAdapter/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter"
test -L "$resources/MediaRemoteAdapter/MediaRemoteAdapter.framework/Versions/Current"
cp "$SRCROOT/THIRD_PARTY_NOTICES.md" "$resources/THIRD_PARTY_NOTICES.md"

/usr/bin/ditto "$SRCROOT/Licenses" "$resources/Licenses"
/bin/bash "$SRCROOT/scripts/build-agent-bridge.sh"
