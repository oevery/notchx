# 发布准备与固定自签

## 版本与身份

`Config/Version.xcconfig` 是版本、构建号、作者和版权的唯一来源，当前为 **0.1.0（1）／oevery**。Xcode、关于页、包名和 Release CI 均读取这些值，不通过 CI 运行次数或 Git 提交数量推导版本。

应用标识仍为 `app.notchx`，辅助程序标识为 `app.notchx.agent-bridge`；不要为了版本重置修改这些身份。NotchX 的版权信息不替代第三方版权和许可。

`Config/Signing/NotchX.cer` 仅包含公钥证书。打包按该证书的精确指纹选择私钥，验证主应用、辅助程序和媒体框架的签名；证书同名但指纹不同不能通过。

## 本地打包

```sh
bash scripts/test.sh --full -resultBundlePath build/pre-release.xcresult
python3 scripts/release.py build
python3 scripts/release.py verify
```

固定身份已在首次配置时创建，默认私密目录为 `~/.local/share/notchx/signing/`，不在仓库内：

- `identity.p12` 与 `signing.password`：带私钥的签名身份及 P12 密码。
- `private-key.pem` 与 `private-key.password`：加密私钥及其密码，用于安全备份／恢复。
- `certificate.pem`：公钥证书副本。

私密目录权限为 700，私密文件权限为 600。请把目录作为敏感材料离线备份；不要提交、粘贴到聊天或上传到产物中。`.gitignore` 只是额外防线，不允许强制添加私钥。

`python3 scripts/release.py init-identity` **仅用于首次创建身份**，现有证书或目录存在时拒绝覆盖。其他机器和 CI 恢复同一份 P12，不重新生成。丢失私钥、证书轮换或以后切换 Developer ID 都需要重新验收授权保留。

可用 `python3 scripts/release.py build --identity-directory /安全的仓库外目录` 指定凭据位置。Xcode 普通 Run 和原生测试继续使用隔离的开发构建，不读取发布私钥；权限升级验收使用固定签名后的 `build/NotchX.app`。

打包只支持 Release：先构建双架构，再由内到外签署媒体框架、桥接程序和主应用。仅修改构建副本，不修改源目录中的第三方框架。构建子进程不继承签名 Secrets；临时钥匙串在成功和失败时均清理。不安装信任根、不修改 Gatekeeper、不移除隔离标记，不安装或启动应用。

产物位于 `build/release/`：版本化的 `NotchX-0.1.0-1-universal-selfsigned.zip`、同名 `.zip.sha256` 与 `.json`。JSON 记录版本、作者、证书指纹、架构、源码提交及脏工作区标记，明确标记未公证。ZIP 解压后再次验证资源、架构、版本和签名，全部通过才输出产物。旧的 `NotchX-developer-universal.zip` 不再更新，不用于本次发布。

## 手动 Release CI 与 Secrets

`.github/workflows/release.yml` 只接受手动触发，仅允许 `oevery/notchx` 的 `main`。单个 `macos-26` 任务先运行 `scripts/test.sh --checks-only`（工程、资源、本地化、版本快速检查），通过后才读取签名凭据，构建 Release、签名、打包并验证解压产物；所有步骤绑定同一次触发的精确提交。不运行 XCTest 或完整测试工具自测，也不分流到 Linux。

测试由本地负责：发布前对准备触发 CI 的同一个干净提交运行不带筛选参数的 `--full`（Core 加工具自测），保留提交 SHA 与 `.xcresult`；若代码变化，重新验证受影响内容及发布前核心测试。窗口和焦点回归须另行显式运行 `--ui`，视觉和真实权限按人工验收清单执行，分别记录已验证／未验证。CI 不自动证明本地测试已通过，核心通过不等于 UI 或真机验收完成，打包成功也不是完整测试通过；首次构建耗时仍须独立观察。

请在仓库创建 **`release-signing` Environment**，限制为 `main` 分支，并在可用时启用人工审批。该 Environment 配置两个 Secrets：

| Secret | 内容 |
| --- | --- |
| `NOTCHX_SIGNING_P12_BASE64` | 同一份 `identity.p12` 的 Base64 编码；Base64 不是加密 |
| `NOTCHX_SIGNING_P12_PASSWORD` | `signing.password` 的内容 |

无需 Apple 账户、Team ID、公证 API Key 或固定钥匙串密码；临时钥匙串密码每次随机生成。不要向普通测试、外部 PR 或其他工作流开放这些 Secrets。

以下命令由所有者在配置好 Environment 后手动运行，通过标准输入上传，不打印秘密：

```sh
base64 < "$HOME/.local/share/notchx/signing/identity.p12" | gh secret set NOTCHX_SIGNING_P12_BASE64 --repo oevery/notchx --env release-signing
gh secret set NOTCHX_SIGNING_P12_PASSWORD --repo oevery/notchx --env release-signing < "$HOME/.local/share/notchx/signing/signing.password"
```

CI 缺少 Secrets、凭据不完整或指纹不符都会失败，绝不降级为 ad-hoc 或无签名包。工作流仅有读取仓库权限，只上传 ZIP、校验和及 JSON；**不创建标签、GitHub Release，不推送提交，不执行公证**。Release 指发布准备流程，不表示已经公开发布。

## 分发与权限限制

固定自签不是 Apple Developer ID，也未经过 Apple 公证，不能承诺默认 Gatekeeper 放行。当前自签流程不启用 Hardened Runtime；以后接入 Developer ID／公证时，需要另行核对媒体框架加载、entitlements 与 Hardened Runtime 兼容性，不能直接声称符合公证条件。

固定证书和应用标识提供跨构建身份，不等于所有隐私权限自动保留。用户需分别验证同包重启、不同构建升级后的辅助功能、自动化、麦克风、语音识别、日历等权限；不自动重置权限或清除隔离属性。

未来正式签名公证需要：Apple Developer Program 资格、Team ID、Developer ID Application 证书及私钥/P12密码，以及公证用 App Store Connect API Key（Key ID、Issuer ID、私钥）或受支持的账户认证材料。这些放入专用 Secrets，不进 Git，本阶段不申请或使用。

参考依据：Apple《Code Signing Guide》的自签证书边界，以及 GitHub《Installing an Apple certificate on macOS runners》的临时钥匙串流程。

## Git 历史与交付边界

重建历史前必须在仓库外保存并验证可恢复备份，再建立只有当前已审查文件的新根提交。其他远端分支、标签、克隆及本地恢复引用可能仍保留旧历史；主线重建不等于旧对象被彻底清除，推送／替换远端历史需单独确认。提交、推送、CI 运行和发布分别授权，不因完成其中一步而自动执行其他步骤。

重建不能删除仍沿用代码的版权和必要来源，也不能靠清历史补救私钥泄露。来源说明保留在 `THIRD_PARTY_NOTICES.md` 与 `Licenses/`，不依赖旧提交号。发布构建应来自确定的干净提交，不能把本地验证包当成已发布版本。
