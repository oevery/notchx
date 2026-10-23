# NotchX

基于 SwiftUI 和 AppKit 的原生 macOS 灵动岛应用，将音乐、设备状态、暂存架、日历、提词器和 Agent 会话集中展示在屏幕顶部。

## 运行

需要 macOS 26 或更新版本、Xcode 26 或更新版本，支持 Apple Silicon 和 Intel。

1. 用 Xcode 打开 `NotchX.xcodeproj`，选择 `NotchX` scheme 和 `My Mac` 后运行。
2. 在设置的模块管理中按需启用功能；主页布局独立配置。
3. 在相关模块设置中手动授予所需权限。关闭模块会停止其工作，保留设置和用户内容。

无需 XcodeGen、Node 或插件安装步骤。模块随应用编译，不支持动态插件商店。上游遥测和自动更新已停用；天气和主动启用的集成仍可能使用网络。

当前版本从 **0.1.0（1）** 开始，由 **oevery** 维护；版本与版权统一配置在 `Config/Version.xcconfig`。Xcode 普通运行默认使用临时签名，重新构建后可能需要重新授权。本地打包与 Release CI 使用同一张固定自签证书，不需要 Apple 开发者账户；私钥只保存在仓库外或 CI Secrets。详见 [发布准备与签名](docs/RELEASE.md)。

## 功能与边界

- **音乐**：媒体信息、播放控制、进度与播放器导航。悬停或点击紧凑音乐区、点击主页音乐标题可打开播放页；展开后的封面打开播放器。进度和播放模式以播放器反馈为准，未知状态不冒充成功。网易云收藏依赖明确授予的辅助功能权限与可识别的中文菜单。
- **设备与信息**：音量、电池、连接状态、日历、天气和通知；可用性取决于硬件、权限和数据源。
- **暂存架**：暂存、搜索、复制、拖放与共享。普通文件作为引用；临时文件和文件承诺转为受管副本。删除引用不删除原文件，受管文件删除失败可重试；用户删除提供十秒撤销。
- **提词器**：文稿编辑、独立草稿、阅读进度恢复与可选语音跟读。恢复阅读不会自动开始录音或请求权限。
- **工具**：保持唤醒与键盘清洁。保持唤醒不阻止合盖或主动睡眠；键盘清洁需辅助功能权限，通过鼠标点击“结束清洁”退出，没有超时或键盘退出快捷键。电源键、Touch ID 和硬件媒体键需真机确认。
- **Agent**：默认关闭，连接已有 Codex Desktop 或 CLI daemon 的原会话，展示活动、计划、子代理、问题和受支持审批。运行中默认“引导”，可“排队”，结束后可“发送”；能力不可用时禁用操作，结果不确定时保留草稿、不自动重发。Hooks 是默认关闭的可选后备，不会因启用 Agent 自动安装或获信任。详见 [Agent 接入](docs/AGENT.md)。

MediaRemoteAdapter 使用 macOS 私有媒体接口，已明确保留，但无法保证未来系统或每个播放器的兼容性。浏览器自动化片段和媒体 Perl 辅助程序属于原生集成，不是插件运行时。

## 发布说明

支持 macOS 26+；Apple Silicon 下载 arm64，Intel 下载 x86_64。打开 DMG，将应用拖入 Applications。固定自签、未经 Apple 公证，首次打开可能被系统拦截；权限按需授予。

下载对应架构的 DMG 和同名 `.sha256` 到同一目录，可用 `shasum -a 256 -c <文件名>.dmg.sha256` 校验。

## 开发与验证

仓库内 `mise.toml` 固定 Python 和 actionlint，并提供本地／CI 共用入口。先审阅并信任该项目配置；缺少工具时由使用者执行 `mise install`，不运行 `mise use -g` 或更改全局 Xcode。

```sh
# 日常核心行为测试：不操作桌面 UI
mise run test

# 发布前核心测试及工具自测：仍不运行桌面 UI
mise run test:full -- -resultBundlePath build/pre-release.xcresult

# 显式桌面 UI 回归：会打开窗口、切换焦点，请单独安排
mise run test:ui -- -resultBundlePath build/desktop-ui.xcresult

# 构建 arm64 和 x86_64 两份 DMG，校验辅助程序、资源与签名
mise run build
```

应用分别位于 `build/arm64/NotchX.app` 和 `build/x86_64/NotchX.app`，带版本号与架构的 DMG、校验和及构建说明位于 `build/release/`。Apple Silicon 选择 arm64，Intel 选择 x86_64；DMG 中将应用拖入 Applications 即可安装。这些是固定自签、未经 Apple 公证的产物，不保证默认 Gatekeeper 放行或升级时所有权限自动保留。构建脚本不会安装或启动应用，不会修改系统信任与安全设置。

增加或删除原生 Swift 文件后，运行 `python3 scripts/generate-xcode-project.py` 并检查工程差异。测试分组在 `TestPlans/Groups.json` 维护；默认 Core，DesktopUI 仅显式运行。CI 支持手动验证及 Release 发布触发，不运行 XCTest；仅发布事件在双架构验证成功后上传附件，修改发布说明不重建。发布前分别确认同一提交的核心自动测试、涉及的 UI 回归和人工验收；核心通过不代表桌面 UI 已验证。详见 [开发与验证](docs/DEVELOPMENT.md) 和 [验收清单](docs/ACCEPTANCE.md)。

## 目录与文档

- `App/`：唯一应用目标，包含宿主、原生模块、设置、本地化与资源。
- `Helpers/`：随应用构建的 Agent 桥接程序。
- `Tests/`：原生应用测试。
- `scripts/`：工程生成、检查、资源处理与打包。
- [架构与所有权](docs/ARCHITECTURE.md)
- [设置组件约定](docs/SETTINGS.md)
- [排序组件](docs/REORDERING.md)
- [第三方来源与许可](THIRD_PARTY_NOTICES.md)
- [发布准备与签名](docs/RELEASE.md)

项目自有文档仅维护中文；界面仍支持系统语言、简体中文和英文。第三方许可证保留原文。当前主线不包含旧 SwiftPM 宿主或 SDK，不另行维护开发流水；必要来源记录保留在当前许可文件中，不依赖旧 Git 历史。
