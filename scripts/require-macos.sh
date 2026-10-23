#!/bin/bash
# 测试与发布命令共用的只读环境预检；不安装工具、不切换 Xcode。
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo "NotchX 完整测试与签名打包需要 macOS 26+、完整 Xcode 26+ 和 macOS SDK 26+。" >&2
  exit 1
fi
notchx_macos_version=$(sw_vers -productVersion)
if [[ ! "$notchx_macos_version" =~ ^([0-9]+)(\.|$) ]] || (( BASH_REMATCH[1] < 26 )); then
  echo "NotchX 需要 macOS 26 或更新版本。" >&2
  exit 1
fi
if ! notchx_xcode_version=$(xcodebuild -version) ||
   [[ ! "$notchx_xcode_version" =~ ^Xcode[[:space:]]+([0-9]+) ]] || (( BASH_REMATCH[1] < 26 )); then
  echo "请选择完整的 Xcode 26 或更新版本；仅有 Command Line Tools 无法构建应用。" >&2
  exit 1
fi
if ! notchx_sdk_version=$(xcrun --sdk macosx --show-sdk-version) ||
   [[ ! "$notchx_sdk_version" =~ ^([0-9]+)(\.|$) ]] || (( BASH_REMATCH[1] < 26 )); then
  echo "当前 Xcode 必须提供 macOS SDK 26 或更新版本。" >&2
  exit 1
fi
echo "环境预检通过：macOS ${notchx_macos_version}；${notchx_xcode_version%%$'\n'*}；macOS SDK ${notchx_sdk_version}。"
