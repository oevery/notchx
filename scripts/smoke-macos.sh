#!/bin/bash
set -euo pipefail
cd -P "$(dirname "$0")/.."
source scripts/require-macos.sh
case "${1:-}" in ''|--verify-resources-only) ;; *) echo "Usage: $0 [--verify-resources-only]" >&2; exit 1 ;; esac
app="${APP_PATH:-$PWD/build/NotchX.app}"
resources="$app/Contents/Resources"
test -x "$app/Contents/MacOS/NotchX"
test -x "$app/Contents/Helpers/NotchXAgentBridge"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
test -x "$resources/MediaRemoteAdapter/mediaremote-adapter.pl"
test -x "$resources/MediaRemoteAdapter/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter"
test -L "$resources/MediaRemoteAdapter/MediaRemoteAdapter.framework/Versions/Current"
test -L "$resources/MediaRemoteAdapter/MediaRemoteAdapter.framework/MediaRemoteAdapter"
test -f "$resources/AppIcon.icns"
if find "$resources" \( -name node_modules -o -name '*.mjs' -o -name '*.cjs' -o -name BundledExtensions \) -print | grep -q .; then
  echo "Forbidden JavaScript extension payload in native bundle." >&2; exit 1
fi
echo "Native bundle structure and approved media adapter verified."
[[ "${1:-}" != --verify-resources-only ]] || exit 0
# Explicit invocation only; process survival does not validate notch/UI behavior.
"$app/Contents/MacOS/NotchX" &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
sleep 5
kill -0 "$pid"
echo "Native process survived five seconds. Physical notch, UI, permissions and multi-display behavior remain manual checks."
