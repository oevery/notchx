# 开发与验证

## 环境与入口

最低 macOS 26，使用 Swift 6 工具链、Swift 5 语言模式和 Xcode 26 或更新版本。不增加旧系统兼容层。应用与测试只有 `NotchX.xcodeproj` 一个工程入口。

`mise.toml` 是项目工具版本的唯一来源：Python 3.15.0、actionlint 1.7.12。任务只调用已有脚本，不复制测试／打包逻辑。已有版本直接复用；缺失工具由使用者显式 `mise install` 安装到工具缓存，不修改全局版本配置。审阅后信任本项目配置；自动化可以仅在进程内设置 `MISE_TRUSTED_CONFIG_PATHS` 为本仓库配置路径，不添加全局信任。Xcode、SDK、Perl、codesign 和 hdiutil 由系统提供；不单独安装 Swift 或替换系统工具。CI 使用固定 SHA 的 mise-action 读取同一配置，工具缓存与签名目录隔离。

```sh
mise run test
mise run test:full -- -resultBundlePath build/pre-release.xcresult
mise run build
mise run test:media -- -resultBundlePath build/media-core.xcresult
mise run test:tools

# 定向核心测试：跳过工具检查，但始终校验分组边界
mise run test -- --native-only -only-testing:NotchXTests/AgentSessionStoreTests

# 仅快速静态检查（与 CI 相同，不构建、不运行 XCTest）
mise run check

# 显式桌面 UI 回归：会打开窗口、切换焦点，需单独安排
mise run test:ui -- -resultBundlePath build/desktop-ui.xcresult

# 按需生成布局 PNG，也必须显式允许桌面 UI
mise run test:ui -- -only-testing:NotchXTests/CompactSlotLayoutTests NOTCHX_CAPTURE_TEST_IMAGES=1

# 修改 Swift 文件清单后同步工程
mise exec -- python3 scripts/generate-xcode-project.py
```

`test.sh` 默认选择 Core：检查工程同步、本地化、版本，然后运行不操作桌面 UI 的核心行为测试。`--full` 在相同 Core 范围上增加检查器和发布工具自测，**不是所有 UI 的全量运行**。`--native-only` 仅跳过工具检查，不绕过 Core 边界；`--daily` 是兼容的 Core 别名。任何检查失败都会终止流程；原生编译同时承担语法和 SDK 类型检查。不再维护 Linux 行为测试或源码裁剪／替换式测试宿主。

Xcode 共享计划为 Core 和 DesktopUI，默认选中 Core。Core 保留协议、文件安全、生命周期、撤权、迟到响应、状态机和偏好兼容；只模拟时钟、权限、硬件和外部通信，不创建窗口或模拟用户输入。即使类名含 Window、Interaction 或 Permission，也按用例实际行为分类，而不是按文件名一刀切。DesktopUI 包含真实窗口、焦点、文件面板、Quick Look、菜单、输入和布局回归，只有 `--ui` 或在 Xcode 中显式选择该计划才运行；不得在日常命令结束后自动追加。

`TestPlans/Groups.json` 是分组来源：纯核心／纯 UI 套件分别列出，混合套件只允许明确列出的核心方法，其他方法归 DesktopUI。生成器拒绝未知套件、重复归属和过期方法，生成互不重叠、覆盖全部用例的明确选择列表；不要手改生成的计划。新增纯核心用例仍须审查其内部调用与测试夹具是否触碰桌面或真实权限。

命令行支持 `-only-testing:`／`-skip-testing:` 缩小范围，但拒绝跨组选择、混合套件整体选择以及覆盖 scheme、配置、测试计划或隔离标志。混合套件请指定组内的单个方法。Debug 核心测试宿主在启动时使用 `.prohibited` 激活策略，并抑制正常应用启动；只有 DesktopUI 计划设置 `NOTCHX_DESKTOP_UI=1`。这些限制仅影响测试进程，不更改用户安装或系统权限。

发布前分别记录核心验证、按需 UI 回归和人工验收结果。`--full` 不带筛选参数才表示完整核心验证；未运行 DesktopUI 时明确记为未验证。每次使用新的 `.xcresult` 路径，Xcode 不覆盖已有结果。外观、动画观感、真实刘海、多屏、真实授权及升级后的权限保留由人工执行 [验收清单](ACCEPTANCE.md)，不能用自动化布局断言代替。

## 脚本职责

- `generate-xcode-project.py`：确定性生成工程、共享 scheme 和 Core/DesktopUI 测试计划，不覆盖个人工作区状态。
- `check-native-project.py`：在隔离目录生成后比对，检查唯一宿主、测试隔离、系统版本、媒体来源清单、文件 SHA-256 与框架链接。
- `check-localization.py`：检查本地化键与格式契约；不检查文档语言。
- `test.sh`：默认 `--core`；`--full` 核心测试加工具自测；`--ui` 显式桌面回归；`--checks-only` 仅运行 CI 快速检查；兼容 `--native-only` 核心定向测试。所有模式执行一次环境预检，不读取发布凭据；测试筛选校验通过后才调用 Xcode。
- `release.py`：统一读取版本信息，`build` 构建固定自签的 arm64／x86_64 两份 DMG；`--arch` 可指定单一架构，`verify --arch` 只读校验身份、元信息、资源与架构，`--dmg` 可复验镜像，不启动应用；见 [发布准备](RELEASE.md)。
- `test-release.py`：验证环境预检、测试入口参数与失败传播、版本契约、实际发布路径的架构／资源拒绝分支、真实 P12 导出、私钥路径／权限、CI 缺少凭据时拒绝降级及临时钥匙串失败清理。
- `build-native-components.sh`：仅供 Xcode 构建阶段调用，组装资源、许可证及已构建的 Agent 辅助程序，保留嵌套代码签名顺序。资源仍每次重新组装，防止删除的资源残留；不再在脚本里调用 Swift 编译器。
- `require-macos.sh`：测试与发布命令共用的只读环境预检，统一要求 macOS、Xcode 和 SDK 均为 26 或更新版本；不自动安装工具或切换 Xcode。
- `prepare-agent-icons.py`：从保留的品牌 SVG 重建 PNG，保留可复现的资源处理路径。

## 测试维护

### MediaRemoteAdapter 更新

`Config/MediaRemoteAdapter.json` 固定上游 tag／commit、构建工具链、命令和当前入库文件 SHA-256；脚本与框架必须来自同一份源码。上游 plist 的 0.1.0 是框架内部版本，不是上游 release 版本。当前使用 v0.7.7，无源码补丁；许可证保留上游原文。

更新时检出清单中的确定提交，用清单命令构建 `MediaRemoteAdapter` 目标（不运行上游测试播放器），保持框架符号链接并同步脚本、框架和校验值。CMake 只在维护第三方框架时需要，普通开发／CI 使用已入库框架；本次构建的 CMake／Xcode／SDK 版本记录在清单，不自动安装或切换本机工具链。不同工具链重建可能产生不同二进制哈希，清单用于验证入库副本，不承诺跨机器逐字节可复现。

`mise run check` 拒绝脚本、框架、许可证或清单不一致；`mise run test:media` 只选择媒体核心套件；`mise run build` 验证两份分架构应用与固定签名。来源清单随应用复制到 `Contents/Resources/MediaRemoteAdapter/Provenance.json`。其中哈希针对原始双架构入库副本，分发包内框架经裁剪／重签后哈希会改变，分发完整性以最终签名和 DMG 校验和为准。

继续使用 `stream --no-diff`，不自动启用无标题输出或实验性防抖。升级后播放、暂停、切歌、seek、封面、播放器切换与系统兼容性仍须人工验收；核心测试不能证明私有接口在真实播放器中可用。

`Tests/` 是原生测试的权威入口。测试生命周期转换、旧结果拒绝、取消、模块停用、选择／置顶、原会话身份和真实副作用，保留失败与权限未知等分支。不为简单 getter、静态枚举映射或类型已保证的行为增加测试。

优先复用真实内部协作，只隔离外部或非确定性边界。日历测试注入事件服务、权限、偏好与调度实例；语音测试注入设备和识别服务，不访问用户日历、麦克风或申请权限。不为测试复制业务实现，不通过减少断言掩盖失败。

设置布局矩阵保留全部语言和宽度；管理操作只在每种语言的窄宽度上重复，宽宽度仍检查布局。等待以页面身份、控件出现和状态变化为条件；动画轨迹与真实超时测试保留必要的时间采样。错误推送测试通过真实 socket 的有序推送、ACK 和 EOF 结束，不为每个错误字段重复等待完整超时；独立无推送场景仍验证真实超时。截图仅在 `NOTCHX_CAPTURE_TEST_IMAGES=1` 时写入 `build/verification/compact-polish/`，并不是图片基准比较。

Agent 辅助程序由 `NotchXAgentBridge` 命令行目标构建，是应用的原生依赖，不是第二个宿主。Xcode 跟踪其源码、SDK、架构与编译选项，Debug 使用 `-Onone` 且只编译当前机器架构，Release 使用 `-O`。Core/DesktopUI 共用 `build/NativeTests`，不要在普通切换时清空构建缓存；发布按 arm64／x86_64 分别构建并验证最终嵌套签名。

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
