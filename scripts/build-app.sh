#!/bin/bash
set -euo pipefail
cd -P "$(dirname "$0")/.."
source scripts/require-macos.sh
if [[ "${CONFIGURATION:-Release}" != Release ]]; then
  echo "发布打包只支持 Release；调试与测试请使用 Xcode 或 test-native.sh。" >&2
  exit 1
fi
# 本地与手动 Release 使用同一入口。缺少固定身份即失败，不退回临时签名。
exec python3 scripts/release.py build "$@"
