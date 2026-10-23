#!/bin/bash
# 唯一完整测试入口：macOS 工具检查与真实应用 XCTest。
set -euo pipefail
cd -P "$(dirname "$0")/.."
bash scripts/require-macos.sh
if [[ "${1:-}" == --native-only ]]; then
  shift
else
  python3 scripts/check-native-project.py
  python3 scripts/check-native-project.py --self-test
  python3 scripts/test-release.py
  python3 scripts/check-localization.py
  python3 scripts/check-localization.py --self-test
fi
# 与完整检查使用同一个应用目标；参数原样交给 xcodebuild。
exec xcodebuild -project NotchX.xcodeproj -scheme NotchX -configuration Debug \
  -derivedDataPath "$PWD/build/NativeTests" -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test "$@"
