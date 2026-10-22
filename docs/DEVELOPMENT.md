# 开发与验证

## 环境与入口

最低 macOS 26，使用 Swift 6 工具链、Swift 5 语言模式和 Xcode 26 或更新版本。不增加旧系统兼容层。应用与测试只有 `NotchX.xcodeproj` 一个工程入口。

```sh
bash scripts/test.sh
bash scripts/build-app.sh

# 定向测试，可继续传入 xcodebuild 参数
bash scripts/test-native.sh -only-testing:NotchXTests/AgentSessionStoreTests

# 修改 Swift 文件清单后同步工程
python3 scripts/generate-xcode-project.py
```

`test.sh` 检查工程同步、双架构校验器、本地化、Swift 语法及保留的独立行为用例；在 macOS 上最后执行原生 XCTest。原生失败必须使总入口失败。Linux 只提供源码与有限行为检查，不能证明原生应用能够编译或运行。

## 脚本职责

- `generate-xcode-project.py`：确定性生成工程和共享 scheme，不覆盖个人工作区状态。
- `check-native-project.py`：在隔离目录生成后比对，检查唯一宿主、测试隔离、系统版本与媒体资源。
- `check-localization.py`：检查本地化键与格式契约；不检查文档语言。
- `validate-native-source.sh`：解析 Swift 语法，不替代 SDK 类型检查。
- `test-module-lifecycle.py`、`test-agent-host.py`、`test-calendar-concurrency.py`、`test-teleprompter-audio-lifecycle.py`：保留独立覆盖的便携行为检查，部分使用源码裁剪与平台替身，不能作为原生集成证明。
- `test-test-routing.py`、`test-universal-architectures.sh`：验证测试入口失败传播和架构校验的拒绝分支。
- `build-app.sh`／`release.py`：统一读取版本信息，构建固定自签双架构应用及 ZIP，校验身份、元信息、资源和解压后的签名；见 [发布准备](RELEASE.md)。
- `test-release.py`：验证版本契约、真实 P12 导出、私钥路径／权限、CI 缺少凭据时拒绝降级及临时钥匙串失败清理。
- `build-agent-bridge.sh`、`copy-native-resources.sh`、`require-macos.sh`、`check-universal-architectures.sh`：构建链共用步骤。
- `prepare-agent-icons.py`：从保留的品牌 SVG 重建 PNG，保留可复现的资源处理路径。
- `smoke-macos.sh --verify-resources-only`：只检查包内资源。省略参数会启动应用，仅在明确需要运行检查时使用；进程存活不证明界面正确。

## 测试维护

`Tests/` 是原生测试的权威入口。测试生命周期转换、旧结果拒绝、取消、模块停用、选择／置顶、原会话身份和真实副作用，保留失败与权限未知等分支。不为简单 getter、静态枚举映射或类型已保证的行为增加测试。

优先复用真实内部协作，只隔离外部或非确定性边界。不为每套平台再维护同一 XCTest 的独立启动器，不通过减少断言掩盖失败。增加便携检查前先确认独立价值。

## 产物与交付

应用图标原图保存在 `Artwork/AppIcon.png`，运行时使用 `App/Resources/AppIcon.icns`。更新图标时从同一原图生成 16、32、128、256、512 点的 1×／2× PNG（最大 1024 像素），通过系统 `iconutil` 封装并反解核对；不要使用对照图或让模型分别重绘各尺寸。

构建和测试产物位于被忽略的 `build/`、`.build/`，不纳入版本控制。GitHub Actions 仅手动触发。普通编译不代表完成分发签名；`build-app.sh` 会执行固定自签及验签，但不代表安装、公证、部署或发布。不要自动启动应用、修改权限、激活系统配置或替换用户安装。

现行文档只维护中文的用途、契约和必要验收项，不追加按日期堆积的开发流水、探针输出或测试次数。第三方许可证与必要来源保留在当前文件中，不依赖旧 Git 历史。真机检查见 [验收清单](ACCEPTANCE.md)。
