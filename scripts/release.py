#!/usr/bin/env python3
"""固定自签身份、版本元数据与本地/CI 共用打包；不发布、不修改系统信任。"""
import argparse
import base64
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote

ROOT = Path(__file__).resolve().parent.parent
CERTIFICATE = ROOT / "Config/Signing/NotchX.cer"
PRIVATE_DIRECTORY = Path.home() / ".local/share/notchx/signing"
APP_ID = "app.notchx"
HELPER_ID = "app.notchx.agent-bridge"
SECRET_ENVIRONMENT = {"NOTCHX_SIGNING_P12_BASE64", "NOTCHX_SIGNING_P12_PASSWORD"}


class CommandFailure(RuntimeError):
    def __init__(self, tool, returncode, stderr):
        self.tool = tool
        self.returncode = returncode
        self.stderr = stderr
        super().__init__(f"{tool} 失败，退出码 {returncode}: {stderr}")


def run(arguments, *, private=False, capture=True, input=None, cwd=ROOT):
    result = subprocess.run([str(arg) for arg in arguments], cwd=cwd, input=input,
                            env={key: value for key, value in os.environ.items() if key not in SECRET_ENVIRONMENT},
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    if result.returncode:
        detail = "（签名凭据命令输出已隐藏）" if private else (result.stderr or b"").decode(errors="replace")
        raise CommandFailure(Path(arguments[0]).name, result.returncode, detail)
    return result.stdout or b""


def metadata(path=None):
    values = {}
    for line in (path or ROOT / "Config/Version.xcconfig").read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("//"):
            continue
        key, separator, value = line.partition("=")
        key, value = key.strip(), value.strip()
        if not separator or key in values:
            raise ValueError("版本配置存在非法行或重复键")
        values[key] = value
    required = {"MARKETING_VERSION", "CURRENT_PROJECT_VERSION", "NOTCHX_AUTHOR", "NOTCHX_COPYRIGHT"}
    if set(values) != required:
        raise ValueError("版本配置键必须完整且唯一")
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", values["MARKETING_VERSION"]):
        raise ValueError("版本必须为三个非负整数，如 0.1.0")
    if not re.fullmatch(r"[1-9][0-9]*", values["CURRENT_PROJECT_VERSION"]):
        raise ValueError("构建号必须为正整数")
    author = values["NOTCHX_AUTHOR"]
    if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?", author):
        raise ValueError("作者必须为有效的 GitHub 账户名形式")
    if not re.fullmatch(r"Copyright © [0-9]{4} " + re.escape(author) + r"\. All rights reserved\.", values["NOTCHX_COPYRIGHT"]):
        raise ValueError("版权信息必须与作者一致")
    return {"version": values["MARKETING_VERSION"], "build": values["CURRENT_PROJECT_VERSION"],
            "author": author, "copyright": values["NOTCHX_COPYRIGHT"], "bundle_id": APP_ID}


ARCHITECTURES = ("arm64", "x86_64")


def artifact_name(meta, arch):
    if arch not in ARCHITECTURES:
        raise ValueError("不支持的发布架构")
    return f"NotchX-{meta['version']}-{meta['build']}-{arch}"


def ci_context():
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("GITHUB_REPOSITORY") != "oevery/notchx":
        raise ValueError("此入口只允许 oevery/notchx 的 GitHub Actions 调用")
    commit = run(["git", "rev-parse", "HEAD"]).decode().strip()
    if commit != os.environ.get("GITHUB_SHA"):
        raise ValueError("检出的提交与触发事件不一致")
    run(["git", "merge-base", "--is-ancestor", commit, "refs/remotes/origin/main"])
    meta = metadata()
    context = {**meta, "commit": commit, "tag": "", "release_id": ""}
    event_name = os.environ.get("GITHUB_EVENT_NAME")
    if event_name == "workflow_dispatch":
        if os.environ.get("GITHUB_REF") != "refs/heads/main":
            raise ValueError("手动验证只允许 main 分支")
        return context
    if event_name != "release":
        raise ValueError("不支持的 CI 事件")
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    release = event.get("release", {})
    tag = release.get("tag_name")
    if event.get("action") != "published" or release.get("draft") is not False:
        raise ValueError("只处理已发布 Release，不处理编辑或草稿事件")
    if tag != f"v{meta['version']}" or os.environ.get("GITHUB_REF") != f"refs/tags/{tag}":
        raise ValueError("Release tag 必须与项目版本完全一致")
    if run(["git", "rev-parse", f"refs/tags/{tag}^{{commit}}"]).decode().strip() != commit:
        raise ValueError("Release tag 已移动或指向其他提交")
    release_id = release.get("id")
    if type(release_id) is not int or release_id <= 0:
        raise ValueError("Release ID 无效")
    return {**context, "tag": tag, "release_id": str(release_id)}


def publish_assets(directory):
    context = ci_context()
    if not context["release_id"]:
        raise ValueError("手动验证不能上传 Release 附件")
    if context["commit"] != os.environ.get("NOTCHX_EXPECTED_COMMIT"):
        raise ValueError("发布任务与构建任务的提交不一致")
    assets = []
    for arch in ARCHITECTURES:
        name = artifact_name(context, arch)
        archive = directory / f"{name}.dmg"
        report_path = directory / f"{name}.json"
        checksum_path = directory / f"{name}.dmg.sha256"
        report = json.loads(report_path.read_text())
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        expected = {"version": context["version"], "build": context["build"],
                    "source_commit": context["commit"], "architectures": [arch],
                    "archive": archive.name, "sha256": digest,
                    "certificate_sha1": certificate_fingerprint(), "signing": "fixed-self-signed"}
        if any(report.get(key) != value for key, value in expected.items()) or report.get("source_dirty") is not False:
            raise ValueError(f"构建报告与发布上下文不一致: {name}")
        if checksum_path.read_text().strip() != f"{digest}  {archive.name}":
            raise ValueError(f"DMG 校验和不一致: {name}")
        verify_dmg(archive, context, arch)
        assets.extend([archive, checksum_path])
    endpoint = f"repos/oevery/notchx/releases/{context['release_id']}"
    current = json.loads(run(["gh", "api", endpoint]))
    if current.get("tag_name") != context["tag"] or current.get("draft") is not False:
        raise ValueError("目标 Release 已变更，拒绝上传")
    pages = json.loads(run(["gh", "api", "--paginate", "--slurp", endpoint + "/assets?per_page=100"]))
    existing = {asset["name"]: asset for page in pages for asset in page}
    pending = []
    # 先核对所有附件，避免有冲突时上传半套；不覆盖同名附件。
    for asset in assets:
        digest = "sha256:" + hashlib.sha256(asset.read_bytes()).hexdigest()
        if asset.name in existing:
            if existing[asset.name].get("digest") != digest or existing[asset.name].get("state") != "uploaded":
                raise ValueError(f"同名 Release 附件不同或未完成，拒绝覆盖: {asset.name}")
        else:
            pending.append(asset)
    for asset in pending:
        url = f"https://uploads.github.com/{endpoint}/assets?name={quote(asset.name)}"
        uploaded = json.loads(run(["gh", "api", "--method", "POST", url, "-H", "Content-Type: application/octet-stream", "--input", asset]))
        if (uploaded.get("state") != "uploaded" or uploaded.get("name") != asset.name
            or uploaded.get("digest") != "sha256:" + hashlib.sha256(asset.read_bytes()).hexdigest()):
            raise ValueError(f"上传后的附件状态或校验和不一致: {asset.name}")
    print("两份 DMG 及各自的 .sha256 已上传（相同附件跳过）；JSON 仅保留在 CI 验证产物中。")


def require_external(path):
    path = path.expanduser().resolve()
    if path == ROOT or ROOT in path.parents:
        raise ValueError("签名私密材料必须放在仓库之外")
    return path


def private_file(path):
    if path.is_symlink():
        raise ValueError("签名凭据不能使用符号链接")
    require_external(path)
    status = path.stat()
    if not path.is_file() or status.st_uid != os.getuid() or status.st_mode & 0o077:
        raise ValueError("签名文件必须由当前用户拥有，且仅当前用户可读写")
    return path.read_bytes()


def initialize_identity(directory):
    directory = require_external(directory)
    if CERTIFICATE.exists() or directory.exists():
        raise ValueError("固定身份已存在或目录已被占用；拒绝覆盖/自动轮换")
    old_umask = os.umask(0o077)
    try:
        directory.mkdir(parents=True, mode=0o700)
        password_path = directory / "signing.password"
        password_path.write_text(secrets.token_urlsafe(48))
        key_password_path = directory / "private-key.password"
        key_password_path.write_text(secrets.token_urlsafe(48))
        key = directory / "private-key.pem"
        public = directory / "certificate.pem"
        # 私钥有密码保护；证书仅用于代码签名，不安装到任何信任域。
        run(["openssl", "req", "-new", "-x509", "-newkey", "rsa:3072", "-sha256",
             "-days", "3650", "-subj", f"/CN=NotchX Signing ({metadata()['author']})/O={metadata()['author']}",
             "-addext", "basicConstraints=critical,CA:TRUE",
             "-addext", "keyUsage=critical,digitalSignature,keyCertSign",
             "-addext", "extendedKeyUsage=codeSigning",
             "-keyout", key, "-out", public, "-passout", f"file:{key_password_path}"], private=True)
        run(["openssl", "pkcs12", "-export", "-inkey", key, "-in", public,
             "-out", directory / "identity.p12", "-name", "NotchX fixed signing identity",
             "-passin", f"file:{key_password_path}", "-passout", f"file:{password_path}",
             "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"], private=True)
        # Security.framework 的 PKCS#12 兼容编码；随机长密码及文件权限保护私钥。
        certificate = run(["openssl", "x509", "-in", public, "-outform", "DER"])
        CERTIFICATE.parent.mkdir(parents=True, exist_ok=True)
        CERTIFICATE.write_bytes(certificate)
        CERTIFICATE.chmod(0o644)
    finally:
        os.umask(old_umask)
    print(f"已创建固定身份；私密材料仅保存在 {directory}")
    print(f"公钥证书 SHA-256: {hashlib.sha256(certificate).hexdigest()}")


@contextmanager
def signing_keychain(directory):
    directory = require_external(directory)
    encoded = os.environ.get("NOTCHX_SIGNING_P12_BASE64")
    ci_password = os.environ.get("NOTCHX_SIGNING_P12_PASSWORD")
    if encoded is not None or ci_password is not None or os.environ.get("CI") == "true":
        if not encoded or not ci_password:
            raise ValueError("CI 必须配置 NOTCHX_SIGNING_P12_BASE64 和 NOTCHX_SIGNING_P12_PASSWORD；不允许降级签名")
        try:
            p12_data = base64.b64decode("".join(encoded.split()), validate=True)
        except ValueError:
            raise ValueError("签名 P12 Base64 无效") from None
        password = ci_password
    else:
        p12_data = private_file(directory / "identity.p12")
        password = private_file(directory / "signing.password").decode().strip()
    if not p12_data or not password:
        raise ValueError("签名凭据不能为空")
    temporary_root = require_external(Path(os.environ.get("RUNNER_TEMP") or tempfile.gettempdir()))
    with tempfile.TemporaryDirectory(prefix="notchx-sign-", dir=temporary_root) as temporary:
        temporary = Path(temporary)
        p12 = temporary / "identity.p12"
        p12.touch(mode=0o600)
        p12.write_bytes(p12_data)
        keychain = temporary / "signing.keychain-db"
        keychain_password = secrets.token_urlsafe(48)
        created = False
        original_search_list = None
        try:
            run(["security", "create-keychain", "-p", keychain_password, keychain], private=True)
            created = True
            run(["security", "set-keychain-settings", "-lut", "21600", keychain], private=True)
            run(["security", "unlock-keychain", "-p", keychain_password, keychain], private=True)
            run(["security", "import", p12, "-k", keychain, "-P", password, "-T", "/usr/bin/codesign"], private=True)
            run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                 "-s", "-k", keychain_password, keychain], private=True)
            # Some runner Security.framework versions do not resolve an identity
            # in an unlisted keychain, even with codesign --keychain. Keep local
            # user settings untouched; scope this change to the Actions runner.
            if os.environ.get("GITHUB_ACTIONS") == "true":
                original_search_list = shlex.split(run(["security", "list-keychains", "-d", "user"], private=True).decode())
                run(["security", "list-keychains", "-d", "user", "-s", keychain, *original_search_list], private=True)
            yield keychain
        finally:
            try:
                if original_search_list is not None:
                    run(["security", "list-keychains", "-d", "user", "-s", *original_search_list], private=True)
            finally:
                if created:
                    run(["security", "delete-keychain", keychain], private=True)


def certificate_fingerprint():
    if not CERTIFICATE.is_file():
        raise ValueError("缺少固定公钥证书，请先执行 init-identity 或恢复同一身份")
    return hashlib.sha1(CERTIFICATE.read_bytes()).hexdigest().upper()


def signature_requirement(identifier):
    return f'identifier "{identifier}" and certificate leaf = H"{certificate_fingerprint()}"'


def verify_signature(path, identifier, *, deep=False):
    run(["codesign", "--verify", "--strict", *(["--deep"] if deep else []),
         "-R", "=" + signature_requirement(identifier), path])


def sign(path, identifier, keychain, *, entitlements=None):
    arguments = ["codesign", "--force", "--sign", certificate_fingerprint(),
                 "--keychain", keychain, "--timestamp=none", "--identifier", identifier]
    if entitlements:
        arguments += ["--entitlements", entitlements]
    run([*arguments, path])
    verify_signature(path, identifier)

def check_signing_identity(keychain):
    fingerprint = certificate_fingerprint()
    imported = run(["security", "find-certificate", "-a", "-Z", keychain], private=True)
    if fingerprint.encode() not in imported.upper():
        raise ValueError("导入的 P12 不包含仓库固定证书，拒绝使用其他身份")
    # Without -v: an intentionally untrusted self-signed certificate can still
    # sign correctly. A real sign/verify probe is authoritative, not trust status.
    identities = run(["security", "find-identity", "-p", "codesigning", keychain], private=True).decode()
    matches = re.findall(r"^\s*\d+\) ([0-9A-Fa-f]{40})\b", identities, re.M)
    if fingerprint not in {value.upper() for value in matches}:
        raise ValueError("临时钥匙串中没有固定证书与私钥配对的签名身份；请检查 P12 是否包含私钥")
    print("固定证书与私钥配对检查通过，执行实际签名探针（不要求系统信任）", flush=True)
    probe = keychain.parent / "signing-probe"
    run(["xcrun", "clang", "-x", "c", "-", "-o", probe], input=b"int main(void) { return 0; }\n")
    sign(probe, "app.notchx.signing-probe", keychain)
    print("固定身份签名及严格验签探针通过；探针不会执行", flush=True)


def framework(app):
    return app / "Contents/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework"


def framework_identifier(app):
    with (framework(app) / "Versions/A/Resources/Info.plist").open("rb") as stream:
        value = plistlib.load(stream)["CFBundleIdentifier"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", value):
        raise ValueError("媒体框架标识无效")
    return value


def verify_architectures(binary, arch):
    architectures = run(["lipo", "-archs", binary]).decode().split()
    if arch not in ARCHITECTURES or architectures != [arch]:
        raise ValueError(f"架构必须恰为 {arch}: {binary.name}，实际 {architectures}")


def verify_resources(app):
    resources = app / "Contents/Resources"
    for executable in [app / "Contents/MacOS/NotchX", app / "Contents/Helpers/NotchXAgentBridge",
                       resources / "MediaRemoteAdapter/mediaremote-adapter.pl",
                       framework(app) / "Versions/A/MediaRemoteAdapter"]:
        if not executable.is_file() or not os.access(executable, os.X_OK):
            raise ValueError(f"应用可执行资源缺失或不可执行: {executable.relative_to(app)}")
    for link in [framework(app) / "Versions/Current", framework(app) / "MediaRemoteAdapter"]:
        if not link.is_symlink() or not link.exists():
            raise ValueError(f"媒体框架链接缺失或失效: {link.relative_to(app)}")
    if not (resources / "AppIcon.icns").is_file():
        raise ValueError("缺少应用图标")
    provenance = resources / "MediaRemoteAdapter/Provenance.json"
    if not provenance.is_file() or provenance.read_bytes() != (ROOT / "Config/MediaRemoteAdapter.json").read_bytes():
        raise ValueError("媒体适配器来源记录缺失或不一致")
    for source in [ROOT / "THIRD_PARTY_NOTICES.md", *(ROOT / "Licenses").rglob("*")]:
        if source.is_file():
            bundled = resources / source.relative_to(ROOT)
            if not bundled.is_file() or bundled.read_bytes() != source.read_bytes():
                raise ValueError(f"第三方许可缺失或不一致: {source.name}")
    for path in resources.rglob("*"):
        if path.name in {"node_modules", "BundledExtensions"} or path.suffix in {".mjs", ".cjs"}:
            raise ValueError(f"应用包含禁止的扩展资源: {path.relative_to(app)}")


def verify_bundle(app, meta, arch):
    verify_resources(app)
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    expected = {"CFBundleIdentifier": APP_ID, "CFBundleShortVersionString": meta["version"],
                "CFBundleVersion": meta["build"], "NSHumanReadableCopyright": meta["copyright"],
                "NotchXAuthor": meta["author"], "CFBundleIconFile": "AppIcon"}
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"应用元信息与唯一配置不一致: {key}")
    helper = app / "Contents/Helpers/NotchXAgentBridge"
    for binary in [app / "Contents/MacOS/NotchX", helper, framework(app) / "Versions/A/MediaRemoteAdapter"]:
        verify_architectures(binary, arch)
    verify_signature(framework(app), framework_identifier(app), deep=True)
    verify_signature(helper, HELPER_ID)
    verify_signature(app, APP_ID, deep=True)


def verify_disk_image(archive):
    delays = (2, 5)
    for attempt in range(1, 4):
        try:
            run(["hdiutil", "verify", archive])
            return
        except CommandFailure as error:
            print(f"hdiutil verify 第 {attempt}/3 次失败: {error}", file=sys.stderr, flush=True)
            # 仅重试明确的 EAGAIN 锁错误；损坏、权限、签名等错误不重试。
            if error.tool != "hdiutil" or "Resource temporarily unavailable" not in error.stderr or attempt == 3:
                raise
            delay = delays[attempt - 1]
            print(f"{delay} 秒后重试同一 DMG，不重新构建或跳过校验", file=sys.stderr, flush=True)
            time.sleep(delay)


def verify_dmg(archive, meta, arch):
    verify_disk_image(archive)
    with tempfile.TemporaryDirectory(prefix="notchx-mount-") as temporary:
        mount = Path(temporary) / "volume"
        run(["hdiutil", "attach", archive, "-readonly", "-nobrowse", "-noautoopen",
             "-mountpoint", mount])
        try:
            link = mount / "Applications"
            if not link.is_symlink() or os.readlink(link) != "/Applications":
                raise ValueError("DMG 缺少 Applications 安装链接")
            verify_bundle(mount / "NotchX.app", meta, arch)
        finally:
            run(["hdiutil", "detach", mount])


def build(directory, arch="arm64"):
    if os.environ.get("CONFIGURATION", "Release") != "Release":
        raise ValueError("发布打包只支持 Release；调试与测试请使用 Xcode 或 test.sh --native-only")
    meta = metadata()
    name = artifact_name(meta, arch)
    derived = ROOT / "build" / f"DerivedData-{arch}"
    run(["openssl", "x509", "-inform", "DER", "-in", CERTIFICATE, "-checkend", "2592000", "-noout"])
    # 编译前验证完整身份及实际签名能力，不把“已导入证书”当成可签名。
    with signing_keychain(directory) as keychain:
        check_signing_identity(keychain)
        run(["python3", "scripts/check-native-project.py"], capture=False)
        run(["xcodebuild", "-project", "NotchX.xcodeproj", "-scheme", "NotchX",
             "-configuration", "Release", "-derivedDataPath", derived,
             "-destination", "generic/platform=macOS", f"ARCHS={arch}", "ONLY_ACTIVE_ARCH=NO",
             "CODE_SIGNING_ALLOWED=NO", "build"], capture=False)
        app = ROOT / "build" / arch / "NotchX.app"
        app.parent.mkdir(parents=True, exist_ok=True)
        if app.is_symlink():
            raise ValueError("拒绝覆盖符号链接应用路径")
        if app.exists():
            shutil.rmtree(app)
        run(["/usr/bin/ditto", derived / "Build/Products/Release/NotchX.app", app])
        binary = framework(app) / "Versions/A/MediaRemoteAdapter"
        available = run(["lipo", "-archs", binary]).decode().split()
        if available != [arch]:
            run(["lipo", binary, "-thin", arch, "-output", binary])
        # 由内到外签名；不使用 --deep 重签，不修改源目录中的第三方框架。
        sign(framework(app), framework_identifier(app), keychain)
        sign(app / "Contents/Helpers/NotchXAgentBridge", HELPER_ID, keychain)
        sign(app, APP_ID, keychain, entitlements=ROOT / "App/NotchX.entitlements")
        verify_bundle(app, meta, arch)
    output = ROOT / "build/release"
    output.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="notchx-package-", dir=ROOT / "build") as temporary:
        temporary = Path(temporary)
        archive = temporary / f"{name}.dmg"
        staging = temporary / "staging"
        staging.mkdir()
        run(["/usr/bin/ditto", app, staging / "NotchX.app"])
        (staging / "Applications").symlink_to("/Applications")
        run(["hdiutil", "create", "-volname", f"NotchX {meta['version']} ({arch})",
             "-srcfolder", staging, "-format", "UDZO", archive])
        verify_dmg(archive, meta, arch)
        checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
        shutil.move(str(archive), output / archive.name)
        (output / f"{name}.dmg.sha256").write_text(f"{checksum}  {name}.dmg\n")
    report = {**meta, "signing": "fixed-self-signed", "notarized": False, "hardened_runtime": False,
              "certificate_sha256": hashlib.sha256(CERTIFICATE.read_bytes()).hexdigest(),
              "certificate_sha1": certificate_fingerprint(), "architectures": [arch],
              "archive": f"{name}.dmg", "sha256": checksum,
              "source_commit": run(["git", "rev-parse", "HEAD"]).decode().strip(),
              "source_dirty": bool(run(["git", "status", "--porcelain"])),
              "notice": "固定自签，未经 Apple 公证；Gatekeeper 与实际权限升级行为仍需人工验收。"}
    (output / f"{name}.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"已生成并验签: {output / (name + '.dmg')}")
    print("仅本地打包：没有安装、启动、系统信任变更、公证、标签或发布。")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["metadata", "init-identity", "build", "verify", "ci-context", "publish-assets"])
    parser.add_argument("--artifacts", type=Path, default=ROOT / "build/release")
    parser.add_argument("--identity-directory", type=Path, default=PRIVATE_DIRECTORY)
    parser.add_argument("--arch", choices=ARCHITECTURES, help="目标架构；build 不指定时依次构建两份 DMG")
    parser.add_argument("--app", type=Path)
    parser.add_argument("--dmg", type=Path)
    args = parser.parse_args()
    if args.command == "ci-context":
        print(json.dumps(ci_context()))
        return
    if args.command == "metadata":
        meta = metadata()
        print(json.dumps({**meta, **({"artifact": artifact_name(meta, args.arch)} if args.arch else {})}))
        return
    run(["bash", ROOT / "scripts/require-macos.sh"], capture=False)
    if args.command == "init-identity":
        initialize_identity(args.identity_directory)
    elif args.command == "publish-assets":
        publish_assets(args.artifacts.resolve())
    elif args.command == "build":
        for arch in ([args.arch] if args.arch else ARCHITECTURES):
            build(args.identity_directory, arch)
    else:
        if not args.arch or (args.app and args.dmg):
            parser.error("verify 必须指定 --arch，且 --app 与 --dmg 不能同时使用")
        if args.dmg:
            verify_dmg(args.dmg.resolve(), metadata(), args.arch)
        else:
            verify_bundle((args.app or ROOT / "build" / args.arch / "NotchX.app").resolve(), metadata(), args.arch)
        print("应用元信息、目标架构、资源和固定签名身份验证通过")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError) as error:
        print(f"Release 失败: {error}", file=sys.stderr)
        sys.exit(1)
