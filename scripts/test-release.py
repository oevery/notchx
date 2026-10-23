#!/usr/bin/env python3
"""验证版本契约、凭据隔离、失败清理；不读取用户私钥或修改系统钥匙串。"""
import base64
import contextlib
import io
import itertools
import hashlib
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

    def test_ci_context_accepts_only_main_manual_or_matching_published_tag(self):
        sha = 'a' * 40
        tag = 'v' + release.metadata()['version']
        event_path = self.directory / 'event.json'
        baseline = {"action": "published", "release": {"id": 123, "tag_name": tag, "draft": False}}
        environment = {"GITHUB_ACTIONS": "true", "GITHUB_REPOSITORY": "oevery/notchx",
                       "GITHUB_SHA": sha, "GITHUB_EVENT_NAME": "release",
                       "GITHUB_REF": f"refs/tags/{tag}", "GITHUB_EVENT_PATH": str(event_path)}
        cases = [({}, {}, {}, True),
                 ({"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main"}, {}, {}, True),
                 ({"GITHUB_EVENT_NAME": "workflow_dispatch"}, {}, {}, False),
                 ({"GITHUB_EVENT_NAME": "push"}, {}, {}, False),
                 ({"GITHUB_REPOSITORY": "other/notchx"}, {}, {}, False),
                 ({"GITHUB_SHA": 'b' * 40}, {}, {}, False),
                 ({}, {"action": "edited"}, {}, False),
                 ({}, {}, {"draft": True}, False),
                 ({}, {}, {"tag_name": "v9.0.0"}, False),
                 ({}, {}, {"id": 0}, False)]
        for env_change, event_change, release_change, accepted in cases:
            event_path.write_text(json.dumps({**baseline, **event_change, "release": {**baseline['release'], **release_change}}))
            with (self.subTest(env=env_change, event=event_change, release=release_change),
                  patch.dict(os.environ, {**environment, **env_change}, clear=True),
                  patch.object(release, "run", return_value=sha.encode()) as execute):
                if accepted:
                    context = release.ci_context()
                    self.assertEqual(context['commit'], sha)
                    self.assertEqual(bool(context['release_id']), not env_change)
                    self.assertIn(["git", "merge-base", "--is-ancestor", sha, "refs/remotes/origin/main"], [c.args[0] for c in execute.call_args_list])
                else:
                    with self.assertRaises(ValueError):
                        release.ci_context()
        event_path.write_text(json.dumps(baseline))
        for failure in ['ancestry', 'moved-tag']:
            def execute(args, **kwargs):
                if args[1] == 'merge-base' and failure == 'ancestry':
                    raise RuntimeError('not on main')
                return ('b' * 40 if failure == 'moved-tag' and args[-1] != 'HEAD' else sha).encode()
            with (self.subTest(failure=failure), patch.dict(os.environ, environment, clear=True),
                  patch.object(release, 'run', side_effect=execute), self.assertRaises((RuntimeError, ValueError))):
                release.ci_context()

    def publish_fixture(self):
        context = {**release.metadata(), 'commit': 'a' * 40, 'tag': 'v' + release.metadata()['version'], 'release_id': '123'}
        files = []
        for arch in release.ARCHITECTURES:
            name = release.artifact_name(context, arch)
            archive = self.directory / (name + '.dmg')
            archive.write_bytes(b'fixture archive ' + arch.encode())
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            checksum = self.directory / (name + '.dmg.sha256')
            checksum.write_text(f'{digest}  {archive.name}\n')
            report = self.directory / (name + '.json')
            report.write_text(json.dumps({**context, 'source_commit': context['commit'], 'source_dirty': False,
                'architectures': [arch], 'archive': archive.name, 'sha256': digest,
                'certificate_sha1': release.certificate_fingerprint(), 'signing': 'fixed-self-signed'}))
            files.extend([archive, checksum, report])
        return context, files

    def test_publish_verifies_both_architectures_and_never_overwrites_conflicting_assets(self):
        context, files = self.publish_fixture()
        public_files = [files[0], files[1], files[3], files[4]]
        remote_assets = [
            {'name': f.name, 'digest': 'sha256:' + hashlib.sha256(f.read_bytes()).hexdigest(), 'state': 'uploaded'}
            for f in public_files
        ]
        for mode in ['new', 'identical', 'partial', 'conflict', 'changed-release', 'bad-upload-response']:
            existing = [asset.copy() for asset in remote_assets]
            if mode in ['new', 'bad-upload-response']: existing = []
            if mode == 'partial': existing = existing[:1]
            if mode == 'conflict': existing[-1]['digest'] = 'sha256:wrong'
            def execute(args, **kwargs):
                if '--slurp' in args: return json.dumps([existing]).encode()
                if '--method' in args:
                    file = args[-1]
                    return json.dumps({'name': file.name, 'state': 'uploaded',
                                       'digest': 'wrong' if mode == 'bad-upload-response' else 'sha256:' + hashlib.sha256(file.read_bytes()).hexdigest()}).encode()
                return json.dumps({'tag_name': 'v9.0.0' if mode == 'changed-release' else context['tag'], 'draft': False}).encode()
            with (self.subTest(mode=mode), patch.object(release, 'ci_context', return_value=context),
                  patch.dict(os.environ, {'NOTCHX_EXPECTED_COMMIT': context['commit']}),
                  patch.object(release, 'verify_dmg') as verify, patch.object(release, 'run', side_effect=execute) as api,
                  contextlib.redirect_stdout(io.StringIO())):
                if mode in ['conflict', 'changed-release', 'bad-upload-response']:
                    with self.assertRaises(ValueError): release.publish_assets(self.directory)
                else:
                    release.publish_assets(self.directory)
                self.assertEqual(verify.call_count, 2)
                uploads = [c.args[0] for c in api.call_args_list if '--method' in c.args[0]]
                self.assertEqual(len(uploads), {'new': 4, 'partial': 3, 'bad-upload-response': 1}.get(mode, 0))
                if mode == 'new':
                    self.assertEqual([c[-1].name for c in uploads], [f.name for f in public_files])
                self.assertTrue(all(file.is_file() for file in files))
                for command in uploads:
                    self.assertNotEqual(command[-1].suffix, '.json')
                    self.assertEqual(command[3], 'POST')
                    self.assertTrue(command[4].startswith('https://uploads.github.com/repos/oevery/notchx/releases/123/assets?name='))

    def test_publish_rejects_manual_missing_or_invalid_artifacts_before_remote_writes(self):
        for failure in ['manual', 'wrong-job-commit', 'missing-intel', 'dirty', 'wrong-report-commit', 'checksum', 'invalid-signature']:
            context, files = self.publish_fixture()
            if failure == 'manual': context['release_id'] = ''
            if failure == 'missing-intel': files[3].unlink()
            if failure in ['dirty', 'wrong-report-commit']:
                report = json.loads(files[5].read_text())
                report.update({'source_dirty': True} if failure == 'dirty' else {'source_commit': 'b' * 40})
                files[5].write_text(json.dumps(report))
            if failure == 'checksum': files[4].write_text('wrong')
            with (self.subTest(failure=failure), patch.object(release, 'ci_context', return_value=context),
                  patch.dict(os.environ, {'NOTCHX_EXPECTED_COMMIT': 'b' * 40 if failure == 'wrong-job-commit' else context['commit']}),
                  patch.object(release, 'verify_dmg', side_effect=RuntimeError('bad signature') if failure == 'invalid-signature' else None),
                  patch.object(release, 'run') as api):
                with self.assertRaises((ValueError, OSError, RuntimeError)):
                    release.publish_assets(self.directory)
                api.assert_not_called()

    def test_disk_image_verification_retries_only_transient_failures_with_bounded_backoff(self):
        temporary = release.CommandFailure('hdiutil', 1, 'verify failed - Resource temporarily unavailable')
        corrupt = release.CommandFailure('hdiutil', 1, 'verify failed - checksum mismatch')
        denied = release.CommandFailure('hdiutil', 1, 'Permission denied')
        other_tool = release.CommandFailure('codesign', 1, 'Resource temporarily unavailable')
        cases = [([b''], [], False), ([temporary, b''], [2], False),
                 ([temporary, temporary, b''], [2, 5], False),
                 ([temporary, temporary, temporary], [2, 5], True),
                 ([corrupt], [], True), ([denied], [], True), ([other_tool], [], True),
                 ([temporary, corrupt], [2], True)]
        for results, waits, fails in cases:
            errors = io.StringIO()
            archive = self.directory / 'same.dmg'
            with (self.subTest(results=results), patch.object(release, 'run', side_effect=results) as execute,
                  patch.object(release.time, 'sleep') as sleep, contextlib.redirect_stderr(errors)):
                if fails:
                    with self.assertRaises(release.CommandFailure) as caught:
                        release.verify_disk_image(archive)
                    self.assertIs(caught.exception, results[-1])
                else:
                    release.verify_disk_image(archive)
                self.assertEqual([c.args[0] for c in sleep.call_args_list], waits)
                self.assertEqual([c.args[0] for c in execute.call_args_list], [['hdiutil', 'verify', archive]] * len(results))
                for index, result in enumerate(results, 1):
                    if isinstance(result, release.CommandFailure):
                        self.assertIn(f'第 {index}/3 次失败', errors.getvalue())
                        self.assertIn(result.stderr, errors.getvalue())

    def test_exhausted_image_verification_never_mounts_or_verifies_bundle(self):
        error = release.CommandFailure('hdiutil', 1, 'Resource temporarily unavailable')
        with (patch.object(release, 'run', side_effect=error) as execute,
              patch.object(release.time, 'sleep'), patch.object(release, 'verify_bundle') as bundle,
              contextlib.redirect_stderr(io.StringIO()), self.assertRaises(release.CommandFailure)):
            release.verify_dmg(self.directory / 'failed.dmg', {}, 'arm64')
        self.assertEqual(execute.call_count, 3)
        self.assertTrue(all(c.args[0][:2] == ['hdiutil', 'verify'] for c in execute.call_args_list))
        bundle.assert_not_called()

    def test_single_metadata_source_controls_archive_name_and_bundle_placeholders(self):
        original = (release.ROOT / "Config/Version.xcconfig").read_text()
        path = self.directory / "Version.xcconfig"
        text = re.sub(r"^MARKETING_VERSION = .+$", "MARKETING_VERSION = 2.3.4", original, flags=re.M)
        path.write_text(re.sub(r"^CURRENT_PROJECT_VERSION = .+$", "CURRENT_PROJECT_VERSION = 27", text, flags=re.M))
        metadata = release.metadata(path)
        for arch in release.ARCHITECTURES:
            self.assertEqual(release.artifact_name(metadata, arch), f"NotchX-2.3.4-27-{arch}")
        with self.assertRaises(ValueError):
            release.artifact_name(metadata, "../invalid")
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

    def test_cli_build_selects_both_or_exact_requested_architecture(self):
        for selected in [None, *release.ARCHITECTURES]:
            arguments = ["release.py", "build"] + (["--arch", selected] if selected else [])
            with (self.subTest(arch=selected), patch.object(release.sys, "argv", arguments),
                  patch.object(release, "run", return_value=b""), patch.object(release, "build") as build):
                release.main()
                self.assertEqual([call.args[1] for call in build.call_args_list],
                                 [selected] if selected else list(release.ARCHITECTURES))

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

    def test_actions_search_list_is_restored_and_keychain_deleted_on_all_exit_paths(self):
        for failure in [None, "register", "body", "restore"]:
            with self.subTest(failure=failure):
                commands = []
                previous = ["/fixture/keychain with spaces.keychain-db", "/fixture/login.keychain-db"]
                def execute(arguments, **kwargs):
                    commands.append(arguments)
                    if arguments[1:] == ["list-keychains", "-d", "user"]:
                        return ('\n'.join('    "'+path+'"' for path in previous)).encode()
                    if arguments[1:5] == ["list-keychains", "-d", "user", "-s"]:
                        restoring = arguments[5:] == previous
                        if failure == ("restore" if restoring else "register"):
                            raise RuntimeError("synthetic search-list failure")
                    return b""
                with (patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "CI": "true",
                         "NOTCHX_SIGNING_P12_BASE64": base64.b64encode(b"synthetic").decode(),
                         "NOTCHX_SIGNING_P12_PASSWORD": "synthetic-password"}, clear=True),
                      patch.object(release, "run", side_effect=execute)):
                    def use_keychain():
                        with release.signing_keychain(self.directory):
                            if failure == "body":
                                raise RuntimeError("synthetic build failure")
                    if failure:
                        with self.assertRaises(RuntimeError):
                            use_keychain()
                    else:
                        use_keychain()
                self.assertEqual(commands[-2], ["security", "list-keychains", "-d", "user", "-s", *previous])
                self.assertEqual(commands[-1][1], "delete-keychain")
                self.assertFalse(any(command[1] in {"add-trusted-cert", "default-keychain"} for command in commands))

    def test_signing_preflight_requires_private_key_pair_and_probes_untrusted_identity(self):
        fingerprint = release.certificate_fingerprint()
        for certificate, identity in [(True, True), (True, False), (False, True)]:
            with self.subTest(certificate=certificate, identity=identity):
                commands = []
                def execute(arguments, **kwargs):
                    commands.append(arguments)
                    if arguments[1] == "find-certificate":
                        return fingerprint.encode() if certificate else b"other"
                    if arguments[1] == "find-identity":
                        self.assertNotIn("-v", arguments)
                        return f'  1) {fingerprint} "fixture" (CSSMERR_TP_NOT_TRUSTED)\n  0 valid identities found'.encode() if identity else b"0 identities found"
                    self.assertEqual(arguments[:2], ["xcrun", "clang"])
                    return b""
                keychain = self.directory / "signing.keychain-db"
                with (patch.object(release, "run", side_effect=execute), patch.object(release, "sign") as sign,
                      contextlib.redirect_stdout(io.StringIO())):
                    if certificate and identity:
                        release.check_signing_identity(keychain)
                        sign.assert_called_once_with(self.directory / "signing-probe", "app.notchx.signing-probe", keychain)
                    else:
                        with self.assertRaises(ValueError):
                            release.check_signing_identity(keychain)
                        sign.assert_not_called()
                        self.assertFalse(any(command[0] == "xcrun" for command in commands))

    def test_failed_signing_probe_stops_before_xcodebuild(self):
        with (patch.object(release, "signing_keychain", return_value=contextlib.nullcontext(self.directory / "signing.keychain-db")),
              patch.object(release, "check_signing_identity", side_effect=RuntimeError("probe failed")) as probe,
              patch.object(release, "run", return_value=b"") as execute):
            with self.assertRaisesRegex(RuntimeError, "probe failed"):
                release.build(self.directory)
            probe.assert_called_once()
            self.assertFalse(any(call.args[0][0] == "xcodebuild" for call in execute.call_args_list))

    def test_verification_pins_certificate_and_identifier_with_an_inline_requirement(self):
        with patch.object(release, "run", return_value=b"") as execute:
            release.verify_signature(Path("example.app"), release.APP_ID, deep=True)
            command = execute.call_args.args[0]
            requirement = command[command.index("-R") + 1]
            self.assertTrue(requirement.startswith("=identifier "))
            self.assertIn(release.APP_ID, requirement)
            self.assertIn(release.certificate_fingerprint(), requirement)
            self.assertIn("--deep", command)

    def test_release_architecture_verification_requires_exact_target_slice(self):
        binary = Path("NotchX")
        for arch in release.ARCHITECTURES:
            for output in [b"arm64", b"x86_64", b"arm64 x86_64", b"", b"arm64e", b"x86_64h"]:
                with self.subTest(arch=arch, output=output), patch.object(release, "run", return_value=output):
                    if output.decode() == arch:
                        release.verify_architectures(binary, arch)
                    else:
                        with self.assertRaises(ValueError):
                            release.verify_architectures(binary, arch)

    def test_dmg_verification_detaches_even_if_bundle_or_install_link_is_invalid(self):
        for failure in [None, "bundle", "link"]:
            commands = []
            def execute(arguments, **kwargs):
                commands.append(arguments)
                if arguments[:2] == ["hdiutil", "attach"]:
                    mount = arguments[-1]
                    mount.mkdir()
                    (mount / "Applications").symlink_to("/invalid" if failure == "link" else "/Applications")
                return b""
            with (self.subTest(failure=failure), patch.object(release, "run", side_effect=execute),
                  patch.object(release, "verify_bundle", side_effect=ValueError("invalid") if failure == "bundle" else None) as verify):
                if failure:
                    with self.assertRaises(ValueError):
                        release.verify_dmg(Path("fixture.dmg"), {}, "arm64")
                else:
                    release.verify_dmg(Path("fixture.dmg"), {}, "arm64")
                    self.assertEqual(verify.call_args.args[1:], ({}, "arm64"))
                self.assertEqual(commands[-1][:2], ["hdiutil", "detach"])
                self.assertTrue(all(flag in commands[1] for flag in ["-readonly", "-nobrowse", "-noautoopen"]))

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
        (resources / "MediaRemoteAdapter/Provenance.json").write_bytes((release.ROOT / "Config/MediaRemoteAdapter.json").read_bytes())
        for source in [release.ROOT / "THIRD_PARTY_NOTICES.md", *(release.ROOT / "Licenses").rglob("*")]:
            if source.is_file():
                target = resources / source.relative_to(release.ROOT)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source.read_bytes())
        return app, executables

    def test_resource_validation_is_read_only_and_rejects_missing_or_nonexecutable_payloads(self):
        app, executables = self.bundle_fixture("valid.app")
        with patch.object(release, "run") as execute:
            release.verify_resources(app)
            execute.assert_not_called()
        for path in [*executables, app / "Contents/Resources/AppIcon.icns",
                     app / "Contents/Resources/MediaRemoteAdapter/Provenance.json",
                     app / "Contents/Resources/THIRD_PARTY_NOTICES.md"]:
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
