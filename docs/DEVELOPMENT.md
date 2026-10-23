# 开发与验证

## 环境与入口

最低 macOS 26，使用 Swift 6 工具链、Swift 5 语言模式和 Xcode 26 或更新版本。不增加旧系统兼容层。应用与测试只有 `NotchX.xcodeproj` 一个工程入口。

```sh
bash scripts/test.sh
python3 scripts/release.py build

# 定向测试，可继续传入 xcodebuild 参数
bash scripts/test.sh --native-only -only-testing:NotchXTests/AgentSessionStoreTests

# 修改 Swift 文件清单后同步工程
python3 scripts/generate-xcode-project.py
```

`test.sh` 是唯一完整入口：在 macOS 上检查工程同步、本地化和发布工具，然后执行真实应用的原生 XCTest。任何检查失败都会终止流程；原生编译同时承担语法和 SDK 类型检查。不再维护 Linux 行为测试或源码裁剪／替换式测试宿主。

## 脚本职责

- `generate-xcode-project.py`：确定性生成工程和共享 scheme，不覆盖个人工作区状态。
- `check-native-project.py`：在隔离目录生成后比对，检查唯一宿主、测试隔离、系统版本与媒体资源。
- `check-localization.py`：检查本地化键与格式契约；不检查文档语言。
- `test.sh`：唯一测试入口；默认完整检查，首个参数 `--native-only` 仅运行 XCTest，其余参数原样传给 Xcode。两种模式都先执行一次环境预检，失败直接返回，不读取发布凭据。
- `release.py`：统一读取版本信息，`build` 构建固定自签双架构应用及 ZIP，`verify` 只读校验身份、元信息、资源与架构，不启动应用；见 [发布准备](RELEASE.md)。
- `test-release.py`：验证环境预检、测试入口参数与失败传播、版本契约、实际发布路径的架构／资源拒绝分支、真实 P12 导出、私钥路径／权限、CI 缺少凭据时拒绝降级及临时钥匙串失败清理。
- `build-native-components.sh`：仅供 Xcode 构建阶段调用，在同一步组装资源、许可证与多架构 Agent 辅助程序，保留嵌套代码签名顺序。
- `require-macos.sh`：测试与发布命令共用的只读环境预检，统一要求 macOS、Xcode 和 SDK 均为 26 或更新版本；不自动安装工具或切换 Xcode。
- `prepare-agent-icons.py`：从保留的品牌 SVG 重建 PNG，保留可复现的资源处理路径。

## 测试维护

`Tests/` 是原生测试的权威入口。测试生命周期转换、旧结果拒绝、取消、模块停用、选择／置顶、原会话身份和真实副作用，保留失败与权限未知等分支。不为简单 getter、静态枚举映射或类型已保证的行为增加测试。

优先复用真实内部协作，只隔离外部或非确定性边界。日历测试注入事件服务、权限、偏好与调度实例；语音测试注入设备和识别服务，不访问用户日历、麦克风或申请权限。不为测试复制业务实现，不通过减少断言掩盖失败。

关键覆盖按职责保留：

| 场景 | 原生测试 |
| --- | --- |
| 模块独立启停、蓝牙权限、停用失败保留重试 | NativeModuleRegistryTests |
| 调度代次、自移除、重入停用和省电截止时间 | ModuleRefreshSchedulerTests |
| 暂存架取消、迟到回调、受管副本与原文件保护 | ShelfTransferTests、ShelfRemovalTests |
| Agent 懒启动、旧订阅拒绝、可信导航和紧凑选择 | AgentHostLifecycleTests、PresentationBehaviorTests |
| 日历目录延迟、最新日期胜出、停用／撤权和提醒去重 | CalendarConcurrencyTests、ModuleReliabilityTests |
| 提词器倒计时、停用恢复、文稿与阅读位置 | TeleprompterSessionTests |
| 音频惰性创建、重复清理、失败重试取消和旧识别回调 | TeleprompterAudioLifecycleTests |

## 产物与交付

应用图标原图保存在 `Artwork/AppIcon.png`，运行时使用 `App/Resources/AppIcon.icns`。更新图标时从同一原图生成 16、32、128、256、512 点的 1×／2× PNG（最大 1024 像素），通过系统 `iconutil` 封装并反解核对；不要使用对照图或让模型分别重绘各尺寸。

构建和测试产物位于被忽略的 `build/`、`.build/`，不纳入版本控制。GitHub Actions 仅手动触发。普通编译不代表完成分发签名；`release.py build` 会执行固定自签及验签，但不代表安装、公证、部署或发布。不再提供自动启动五秒的存活检查。不要自动启动应用、修改权限、激活系统配置或替换用户安装。

现行文档只维护中文的用途、契约和必要验收项，不追加按日期堆积的开发流水、探针输出或测试次数。第三方许可证与必要来源保留在当前文件中，不依赖旧 Git 历史。真机检查见 [验收清单](ACCEPTANCE.md)。
