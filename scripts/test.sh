#!/bin/bash
# 默认仅核心行为测试；桌面 UI 必须显式使用 --ui。
set -euo pipefail
cd -P "$(dirname "$0")/.."
mode=--core
case "${1:-}" in
  --core|--daily|--full|--ui|--checks-only|--native-only) mode="$1"; shift ;;
  --help) echo '用法: test.sh [--core|--full|--ui|--checks-only|--native-only] [测试筛选／结果参数]'; exit 0 ;;
  --*) echo "未知模式: $1" >&2; exit 2 ;;
esac
if [[ "$mode" == --checks-only && $# != 0 ]]; then
  echo '--checks-only 不接受 Xcode 参数' >&2; exit 2
fi
bash scripts/require-macos.sh
if [[ "$mode" != --native-only ]]; then
  python3 scripts/check-native-project.py
  python3 scripts/check-localization.py
  python3 scripts/release.py metadata
fi
if [[ "$mode" == --checks-only ]]; then exit 0; fi
plan=Core
if [[ "$mode" == --full ]]; then
  python3 scripts/check-native-project.py --self-test
  python3 scripts/test-release.py
  python3 scripts/check-localization.py --self-test
elif [[ "$mode" == --ui ]]; then
  plan=DesktopUI
  echo '注意：显式 UI 回归会打开窗口、改变焦点并模拟交互，请勿同时操作桌面。'
fi
python3 scripts/check-native-project.py --test-selection "$plan" "$@"
echo "运行本地 $plan 测试计划（额外筛选参数会缩小实际覆盖）"
# 与完整检查使用同一个应用目标；参数原样交给 xcodebuild。
exec xcodebuild -project NotchX.xcodeproj -scheme NotchX -configuration Debug \
  -derivedDataPath "$PWD/build/NativeTests" -destination 'platform=macOS' \
  -testPlan "$plan" CODE_SIGNING_ALLOWED=NO test "$@"
