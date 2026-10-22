#!/bin/bash
# Source this before native build/test operations.
if [[ "$(uname -s)" != Darwin ]]; then
  echo "Native NotchX validation requires macOS 26+ with full Xcode 26+ and the macOS SDK. Linux can run portable tests and Swift syntax parsing only." >&2
  exit 1
fi
notchx_macos_version=$(/usr/bin/sw_vers -productVersion)
if (( ${notchx_macos_version%%.*} < 26 )); then
  echo "Native NotchX validation requires macOS 26 or later." >&2
  exit 1
fi
if ! xcodebuild -version || ! xcrun --sdk macosx --show-sdk-path; then
  echo "Select a full Xcode installation with xcode-select; Command Line Tools alone cannot build the app." >&2
  exit 1
fi
