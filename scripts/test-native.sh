#!/bin/bash
set -euo pipefail
cd -P "$(dirname "$0")/.."
source scripts/require-macos.sh
# 测试真实 App/ 目标；隔离宿主不启动常规模块或申请系统权限。
xcodebuild -project NotchX.xcodeproj -scheme NotchX -configuration Debug \
  -derivedDataPath "$PWD/build/NativeTests" -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test "$@"
