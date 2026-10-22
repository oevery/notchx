#!/usr/bin/env python3
"""验证版本契约、凭据隔离、失败清理；不读取用户私钥或修改系统钥匙串。"""
import base64
import contextlib
import io
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


if __name__ == "__main__":
    unittest.main()
