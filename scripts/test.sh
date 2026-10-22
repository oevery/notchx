#!/bin/bash
# 统一入口：各平台执行源码检查，macOS 额外运行原生 XCTest。
set -euo pipefail
cd -P "$(dirname "$0")/.."
python3 scripts/check-native-project.py
python3 scripts/check-native-project.py --self-test
python3 scripts/test-release.py
bash scripts/test-universal-architectures.sh
python3 scripts/check-localization.py
python3 scripts/check-localization.py --self-test
bash scripts/validate-native-source.sh
python3 scripts/test-module-lifecycle.py
python3 scripts/test-agent-host.py
python3 scripts/test-test-routing.py
python3 scripts/test-teleprompter-audio-lifecycle.py
python3 scripts/test-calendar-concurrency.py
if [[ "$(uname -s)" == Darwin ]]; then
  bash scripts/test-native.sh "$@"
else
  echo "Source checks passed. Native app compilation and XCTest require macOS/Xcode."
fi
