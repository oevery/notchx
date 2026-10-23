#!/usr/bin/env python3
"""验证版本契约、凭据隔离、失败清理；不读取用户私钥或修改系统钥匙串。"""
import base64
import contextlib
import io
import itertools
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import release


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="notchx-release-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def test_single_metadata_source_controls_archive_name_and_bundle_placeholders(self):
        original = (release.ROOT / "Config/Version.xcconfig").read_text()
        path = self.directory / "Version.xcconfig"
        text = re.sub(r"^MARKETING_VERSION = .+$", "MARKETING_VERSION = 2.3.4", original, flags=re.M)
        path.write_text(re.sub(r"^CURRENT_PROJECT_VERSION = .+$", "CURRENT_PROJECT_VERSION = 27", text, flags=re.M))
        metadata = release.metadata(path)
        self.assertEqual(release.artifact_name(metadata), "NotchX-2.3.4-27-universal-selfsigned")
        with (release.ROOT / "App/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        self.assertEqual(info["CFBundleShortVersionString"], "$(MARKETING_VERSION)")
        self.assertEqual(info["CFBundleVersion"], "$(CURRENT_PROJECT_VERSION)")
        self.assertEqual(info["NotchXAuthor"], "$(NOTCHX_AUTHOR)")
        self.assertEqual(info["NSHumanReadableCopyright"], "$(NOTCHX_COPYRIGHT)")

    def test_unsafe_or_inconsistent_metadata_is_rejected(self):
        original = (release.ROOT / "Config/Version.xcconfig").read_text()
        variants = [re.sub(r"^MARKETING_VERSION = .+$", "MARKETING_VERSION = ../../release", original, flags=re.M),
                    re.sub(r"^MARKETING_VERSION = .+$", "MARKETING_VERSION = 01.1.0", original, flags=re.M),
                    re.sub(r"^MARKETING_VERSION = .+$", "MARKETING_VERSION = 0/1/0", original, flags=re.M),
                    re.sub(r"^CURRENT_PROJECT_VERSION = .+$", "CURRENT_PROJECT_VERSION = 0", original, flags=re.M),
                    original.replace("NOTCHX_AUTHOR = oevery", "NOTCHX_AUTHOR = someone-else"),
                    original + "\nMARKETING_VERSION = 2.0.0\n"]
        for index, text in enumerate(variants):
            with self.subTest(index=index):
                path = self.directory / "Version.xcconfig"
                path.write_text(text)
                with self.assertRaises(ValueError):
                    release.metadata(path)

    def test_private_material_in_repository_or_with_unsafe_permissions_is_rejected(self):
        with self.assertRaises(ValueError):
            release.require_external(release.ROOT / "build/identity.p12")
        private = self.directory / "identity.p12"
        private.write_bytes(b"synthetic")
        private.chmod(0o644)
        with self.assertRaises(ValueError):
            release.private_file(private)
        private.chmod(0o600)
        self.assertEqual(release.private_file(private), b"synthetic")
        link = self.directory / "linked.p12"
        link.symlink_to(private)
        with self.assertRaises(ValueError):
            release.private_file(link)

    def test_ci_cannot_fall_back_to_local_identity(self):
        for variables in [{"CI": "true"}, {"NOTCHX_SIGNING_P12_PASSWORD": "synthetic"},
                          {"NOTCHX_SIGNING_P12_BASE64": "invalid"}]:
            with self.subTest(variables=list(variables)), patch.dict(os.environ, variables, clear=True):
                with patch.object(release, "private_file") as read, self.assertRaises(ValueError):
                    with release.signing_keychain(self.directory):
                        self.fail("Missing CI credentials reached signing")
                read.assert_not_called()

    def test_temporary_keychain_and_credential_files_are_cleaned_on_success_and_import_failure(self):
        for fail_import in [False, True]:
            with self.subTest(fail_import=fail_import):
                commands, files = [], []

                def execute(arguments, **kwargs):
                    commands.append(arguments)
                    self.assertTrue(kwargs.get("private"))
                    if arguments[1] == "import":
                        path = Path(arguments[2])
                        files.append(path)
                        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                        self.assertEqual(path.read_bytes(), b"synthetic")
                        self.assertNotIn(release.ROOT, path.parents)
                        if fail_import:
                            raise RuntimeError("synthetic import failure")
                    return b""

                with patch.dict(os.environ, {"CI": "true", "NOTCHX_SIGNING_P12_BASE64": base64.b64encode(b"synthetic").decode(),
                                             "NOTCHX_SIGNING_P12_PASSWORD": "synthetic-password"}, clear=True), patch.object(release, "run", side_effect=execute):
                    if fail_import:
                        with self.assertRaisesRegex(RuntimeError, "synthetic import failure"):
                            with release.signing_keychain(self.directory):
                                self.fail("Import failure reached signing")
                    else:
                        with release.signing_keychain(self.directory):
                            pass
                self.assertEqual(commands[-1][1], "delete-keychain")
                self.assertFalse(any(path.exists() for path in files))
                self.assertFalse(any(command[1] in {"add-trusted-cert", "list-keychains", "default-keychain"} for command in commands))

    def test_credentials_are_not_inherited_by_build_commands_or_included_in_errors(self):
        completed = subprocess.CompletedProcess([], 1, b"", b"synthetic-password")
        with patch.dict(os.environ, {"NOTCHX_SIGNING_P12_PASSWORD": "synthetic-password", "NOTCHX_SIGNING_P12_BASE64": "synthetic-base64"}), \
             patch.object(release.subprocess, "run", return_value=completed) as execute:
            with self.assertRaises(RuntimeError) as caught:
                release.run(["security", "import", "fixture"], private=True)
            self.assertNotIn("synthetic-password", str(caught.exception))
            self.assertTrue(release.SECRET_ENVIRONMENT.isdisjoint(execute.call_args.kwargs["env"]))

    def test_verification_pins_certificate_and_identifier_with_an_inline_requirement(self):
        with patch.object(release, "run", return_value=b"") as execute:
            release.verify_signature(Path("example.app"), release.APP_ID, deep=True)
            command = execute.call_args.args[0]
            requirement = command[command.index("-R") + 1]
            self.assertTrue(requirement.startswith("=identifier "))
            self.assertIn(release.APP_ID, requirement)
            self.assertIn(release.certificate_fingerprint(), requirement)
            self.assertIn("--deep", command)

    def test_release_architecture_verification_rejects_thin_and_substring_matches(self):
        binary = Path("NotchX")
        for output in [b"arm64 x86_64", b"x86_64 arm64", b"  arm64\tx86_64\n"]:
            with self.subTest(output=output), patch.object(release, "run", return_value=output) as execute:
                release.verify_architectures(binary)
                execute.assert_called_once_with(["lipo", "-archs", binary])
        for output in [b"arm64", b"x86_64", b"", b"arm64e x86_64", b"arm64 x86_64h"]:
            with self.subTest(output=output), patch.object(release, "run", return_value=output):
                with self.assertRaises(ValueError):
                    release.verify_architectures(binary)

    def test_identity_generation_exports_real_p12_and_refuses_to_replace_existing_identity(self):
        public = self.directory / "public/NotchX.cer"
        private = self.directory / "private"
        with patch.object(release, "CERTIFICATE", public), contextlib.redirect_stdout(io.StringIO()):
            release.initialize_identity(private)
            original = public.read_bytes()
            self.assertGreater(len(original), 100)
            self.assertEqual((private / "identity.p12").stat().st_mode & 0o777, 0o600)
            # 真实解密校验 PKCS#12，避免把只生成证书但导出失败当成成功。
            release.run(["openssl", "pkcs12", "-in", private / "identity.p12", "-noout",
                         "-passin", f"file:{private / 'signing.password'}"], private=True)
            with self.assertRaises(ValueError):
                release.initialize_identity(private)
            self.assertEqual(public.read_bytes(), original)

    def bundle_fixture(self, name):
        app = self.directory / name
        resources = app / "Contents/Resources"
        executables = [app / "Contents/MacOS/NotchX", app / "Contents/Helpers/NotchXAgentBridge",
                       resources / "MediaRemoteAdapter/mediaremote-adapter.pl",
                       release.framework(app) / "Versions/A/MediaRemoteAdapter"]
        for path in executables:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixture, never executed")
            path.chmod(0o755)
        (release.framework(app) / "Versions/Current").symlink_to("A")
        (release.framework(app) / "MediaRemoteAdapter").symlink_to("Versions/Current/MediaRemoteAdapter")
        (resources / "AppIcon.icns").write_bytes(b"fixture")
        return app, executables

    def test_resource_validation_is_read_only_and_rejects_missing_or_nonexecutable_payloads(self):
        app, executables = self.bundle_fixture("valid.app")
        with patch.object(release, "run") as execute:
            release.verify_resources(app)
            execute.assert_not_called()
        for path in [*executables, app / "Contents/Resources/AppIcon.icns"]:
            with self.subTest(missing=path.name):
                contents, mode = path.read_bytes(), path.stat().st_mode
                path.unlink()
                with self.assertRaises(ValueError):
                    release.verify_resources(app)
                path.write_bytes(contents)
                path.chmod(mode)
        for path in executables:
            with self.subTest(nonexecutable=path.name):
                path.chmod(0o644)
                with self.assertRaises(ValueError):
                    release.verify_resources(app)
                path.chmod(0o755)

    def test_resource_validation_rejects_broken_framework_links_and_extension_payloads(self):
        for index, relative in enumerate(["Versions/Current", "MediaRemoteAdapter"]):
            app, _ = self.bundle_fixture(f"link-{index}.app")
            link = release.framework(app) / relative
            link.unlink()
            link.symlink_to("missing")
            with self.subTest(link=relative), self.assertRaises(ValueError):
                release.verify_resources(app)
        for index, name in enumerate(["node_modules", "BundledExtensions", "example.mjs", "example.cjs"]):
            app, _ = self.bundle_fixture(f"extension-{index}.app")
            (app / "Contents/Resources" / name).touch()
            with self.subTest(payload=name), self.assertRaises(ValueError):
                release.verify_resources(app)

    def test_cli_preflight_failure_stops_before_any_signing_or_verification(self):
        for command, operation in [("build", "build"), ("verify", "verify_bundle"), ("init-identity", "initialize_identity")]:
            with self.subTest(command=command), patch.object(release.sys, "argv", ["release.py", command]), \
                 patch.object(release, "run", side_effect=RuntimeError("preflight failed")) as execute, \
                 patch.object(release, operation) as action:
                with self.assertRaisesRegex(RuntimeError, "preflight failed"):
                    release.main()
                execute.assert_called_once_with(["bash", release.ROOT / "scripts/require-macos.sh"], capture=False)
                action.assert_not_called()
        with patch.dict(os.environ, {"CONFIGURATION": "Debug"}), patch.object(release, "signing_keychain") as signing:
            with self.assertRaises(ValueError):
                release.build(self.directory)
            signing.assert_not_called()

    def tool_environment(self):
        binary = self.directory / "bin"
        binary.mkdir()
        log = self.directory / "commands.log"
        stubs = {
            "uname": 'printf "%s\\n" "${FIXTURE_OS:-Darwin}"',
            "sw_vers": 'printf "%s\\n" "${FIXTURE_MACOS:-26.0}"',
            "xcrun": 'printf "%s\\n" "${FIXTURE_SDK:-26.0}"',
            "xcodebuild": '''if [[ "$1" == -version ]]; then
  printf '%s\\n' preflight >> "$FIXTURE_LOG"
  printf 'Xcode %s\\nBuild version fixture\\n' "${FIXTURE_XCODE:-26.0}"
  exit 0
fi
printf '%s\\n' xcodebuild "$@" >> "$FIXTURE_LOG"
exit "${FIXTURE_NATIVE_EXIT:-0}"''',
            "python3": '''printf '%s\\n' "$*" >> "$FIXTURE_LOG"
exit "${FIXTURE_PYTHON_EXIT:-0}"''',
        }
        for name, source in stubs.items():
            path = binary / name
            path.write_text("#!/bin/bash\n" + source + "\n")
            path.chmod(0o755)
        return {**os.environ, "PATH": str(binary) + os.pathsep + os.environ["PATH"], "FIXTURE_LOG": str(log)}, log

    def test_shared_preflight_rejects_unsupported_os_xcode_and_sdk(self):
        environment, _ = self.tool_environment()
        for variables in [{}, {"FIXTURE_OS": "Linux"}, {"FIXTURE_MACOS": "15.0"},
                          {"FIXTURE_XCODE": "16.4"}, {"FIXTURE_SDK": "15.5"}, {"FIXTURE_XCODE": "invalid"}]:
            with self.subTest(variables=variables):
                result = subprocess.run(["/bin/bash", str(release.ROOT / "scripts/require-macos.sh")],
                                        env={**environment, **variables}, capture_output=True)
                self.assertEqual(result.returncode == 0, not variables)

    def test_core_full_and_explicit_ui_preserve_arguments_and_failure_status(self):
        environment, log = self.tool_environment()
        # xcodebuild/python3 are recording stubs; this never launches desktop UI.
        for mode, (python_exit, native_exit) in itertools.product(
                [None, "--core", "--daily", "--full", "--native-only", "--ui"], [(0, 0), (0, 37), (41, 0)]):
            with self.subTest(mode=mode, python_exit=python_exit, native_exit=native_exit):
                log.write_text("")
                selected = "SettingsPresentationTests" if mode == "--ui" else "CalendarConcurrencyTests"
                arguments = ([mode] if mode else []) + [f"-only-testing:NotchXTests/{selected}", "-resultBundlePath", "path with spaces.xcresult"]
                result = subprocess.run(["/bin/bash", str(release.ROOT / "scripts/test.sh"), *arguments],
                    env={**environment, "FIXTURE_PYTHON_EXIT": str(python_exit), "FIXTURE_NATIVE_EXIT": str(native_exit)}, capture_output=True)
                checks_failed = bool(python_exit)
                self.assertEqual(result.returncode, python_exit if checks_failed else native_exit)
                commands = log.read_text().splitlines()
                self.assertEqual(commands.count("preflight"), 1)
                self.assertEqual("scripts/test-release.py" in commands, mode == "--full" and not python_exit)
                self.assertEqual("xcodebuild" in commands, not checks_failed)
                if not checks_failed:
                    self.assertEqual(commands[-3:], arguments[-3:])
                    plan = "DesktopUI" if mode == "--ui" else "Core"
                    self.assertEqual(commands[commands.index("-testPlan") + 1], plan)
                    self.assertTrue(any(command.startswith(f"scripts/check-native-project.py --test-selection {plan} ") for command in commands))
                    self.assertNotIn(mode, commands)

    def test_ci_checks_never_build_or_run_tests_and_propagate_failures(self):
        environment, log = self.tool_environment()
        for failure in [0, 41]:
            log.write_text("")
            result = subprocess.run(["/bin/bash", str(release.ROOT / "scripts/test.sh"), "--checks-only"],
                env={**environment, "FIXTURE_PYTHON_EXIT": str(failure)}, capture_output=True)
            self.assertEqual(result.returncode, failure)
            commands = log.read_text().splitlines()
            self.assertEqual(commands.count("preflight"), 1)
            self.assertNotIn("xcodebuild", commands)
            self.assertNotIn("scripts/test-release.py", commands)
            self.assertFalse(any("--self-test" in command for command in commands))
            if not failure:
                self.assertIn("scripts/check-native-project.py", commands)
                self.assertIn("scripts/check-localization.py", commands)
                self.assertIn("scripts/release.py metadata", commands)
        for arguments in [["--checks-only", "-quiet"], ["--unknown"]]:
            result = subprocess.run(["/bin/bash", str(release.ROOT / "scripts/test.sh"), *arguments],
                                    env=environment, capture_output=True)
            self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
