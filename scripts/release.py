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
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
CERTIFICATE = ROOT / "Config/Signing/NotchX.cer"
PRIVATE_DIRECTORY = Path.home() / ".local/share/notchx/signing"
APP_ID = "app.notchx"
HELPER_ID = "app.notchx.agent-bridge"
SECRET_ENVIRONMENT = {"NOTCHX_SIGNING_P12_BASE64", "NOTCHX_SIGNING_P12_PASSWORD"}


def run(arguments, *, private=False, capture=True, input=None, cwd=ROOT):
    result = subprocess.run([str(arg) for arg in arguments], cwd=cwd, input=input,
                            env={key: value for key, value in os.environ.items() if key not in SECRET_ENVIRONMENT},
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    if result.returncode:
        detail = "（签名凭据命令输出已隐藏）" if private else (result.stderr or b"").decode(errors="replace")
        raise RuntimeError(f"{Path(arguments[0]).name} 失败，退出码 {result.returncode}: {detail}")
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


def artifact_name(meta):
    return f"NotchX-{meta['version']}-{meta['build']}-universal-selfsigned"


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
        try:
            run(["security", "create-keychain", "-p", keychain_password, keychain], private=True)
            created = True
            run(["security", "set-keychain-settings", "-lut", "21600", keychain], private=True)
            run(["security", "unlock-keychain", "-p", keychain_password, keychain], private=True)
            run(["security", "import", p12, "-k", keychain, "-P", password, "-T", "/usr/bin/codesign"], private=True)
            run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                 "-s", "-k", keychain_password, keychain], private=True)
            yield keychain
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


def framework(app):
    return app / "Contents/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework"


def framework_identifier(app):
    with (framework(app) / "Versions/A/Resources/Info.plist").open("rb") as stream:
        value = plistlib.load(stream)["CFBundleIdentifier"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", value):
        raise ValueError("媒体框架标识无效")
    return value


def verify_architectures(binary):
    architectures = run(["lipo", "-archs", binary]).decode().split()
    if not {"arm64", "x86_64"}.issubset(architectures):
        raise ValueError(f"缺少双架构: {binary.name}")


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
    for path in resources.rglob("*"):
        if path.name in {"node_modules", "BundledExtensions"} or path.suffix in {".mjs", ".cjs"}:
            raise ValueError(f"应用包含禁止的扩展资源: {path.relative_to(app)}")


def verify_bundle(app, meta):
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
        verify_architectures(binary)
    verify_signature(framework(app), framework_identifier(app), deep=True)
    verify_signature(helper, HELPER_ID)
    verify_signature(app, APP_ID, deep=True)


def build(directory):
    if os.environ.get("CONFIGURATION", "Release") != "Release":
        raise ValueError("发布打包只支持 Release；调试与测试请使用 Xcode 或 test.sh --native-only")
    meta = metadata()
    fingerprint = certificate_fingerprint()
    run(["openssl", "x509", "-inform", "DER", "-in", CERTIFICATE, "-checkend", "2592000", "-noout"])
    # 先验证凭据能导入；整个步骤缺少身份即失败，不产生伪装成成功的无签名发布包。
    with signing_keychain(directory) as keychain:
        imported = run(["security", "find-certificate", "-a", "-Z", keychain], private=True)
        if fingerprint.encode() not in imported.upper():
            raise ValueError("导入的 P12 不包含仓库固定证书，拒绝使用其他身份")
        run(["python3", "scripts/check-native-project.py"], capture=False)
        run(["xcodebuild", "-project", "NotchX.xcodeproj", "-scheme", "NotchX",
             "-configuration", "Release", "-derivedDataPath", ROOT / "build/DerivedData",
             "-destination", "generic/platform=macOS", "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO",
             "CODE_SIGNING_ALLOWED=NO", "build"], capture=False)
        app = ROOT / "build/NotchX.app"
        if app.is_symlink():
            raise ValueError("拒绝覆盖符号链接应用路径")
        if app.exists():
            shutil.rmtree(app)
        run(["/usr/bin/ditto", ROOT / "build/DerivedData/Build/Products/Release/NotchX.app", app])
        # 由内到外签名；不使用 --deep 重签，不修改源目录中的第三方框架。
        sign(framework(app), framework_identifier(app), keychain)
        sign(app / "Contents/Helpers/NotchXAgentBridge", HELPER_ID, keychain)
        sign(app, APP_ID, keychain, entitlements=ROOT / "App/NotchX.entitlements")
        verify_bundle(app, meta)
    output = ROOT / "build/release"
    output.mkdir(exist_ok=True)
    name = artifact_name(meta)
    with tempfile.TemporaryDirectory(prefix="notchx-package-", dir=ROOT / "build") as temporary:
        temporary = Path(temporary)
        archive = temporary / f"{name}.zip"
        run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive])
        extracted = temporary / "extracted"
        run(["/usr/bin/ditto", "-x", "-k", archive, extracted])
        verify_bundle(extracted / "NotchX.app", meta)
        checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
        shutil.move(str(archive), output / archive.name)
        (output / f"{name}.zip.sha256").write_text(f"{checksum}  {name}.zip\n")
    report = {**meta, "signing": "fixed-self-signed", "notarized": False, "hardened_runtime": False,
              "certificate_sha256": hashlib.sha256(CERTIFICATE.read_bytes()).hexdigest(),
              "certificate_sha1": fingerprint, "architectures": ["arm64", "x86_64"],
              "archive": f"{name}.zip", "sha256": checksum,
              "source_commit": run(["git", "rev-parse", "HEAD"]).decode().strip(),
              "source_dirty": bool(run(["git", "status", "--porcelain"])),
              "notice": "固定自签，未经 Apple 公证；Gatekeeper 与实际权限升级行为仍需人工验收。"}
    (output / f"{name}.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"已生成并验签: {output / (name + '.zip')}")
    print("仅本地打包：没有安装、启动、系统信任变更、公证、标签或发布。")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["metadata", "init-identity", "build", "verify"])
    parser.add_argument("--identity-directory", type=Path, default=PRIVATE_DIRECTORY)
    parser.add_argument("--app", type=Path, default=ROOT / "build/NotchX.app")
    args = parser.parse_args()
    if args.command == "metadata":
        meta = metadata()
        print(json.dumps({**meta, "artifact": artifact_name(meta)}))
        return
    run(["bash", ROOT / "scripts/require-macos.sh"], capture=False)
    if args.command == "init-identity":
        initialize_identity(args.identity_directory)
    elif args.command == "build":
        build(args.identity_directory)
    else:
        verify_bundle(args.app.resolve(), metadata())
        print("应用元信息、双架构、资源和固定签名身份验证通过")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError) as error:
        print(f"Release 失败: {error}", file=sys.stderr)
        sys.exit(1)
