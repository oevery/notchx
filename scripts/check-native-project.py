#!/usr/bin/env python3
"""Verify checked-in project is current and source/resource ownership is native-only."""
from pathlib import Path
import subprocess
import tempfile
import shutil
import re
import sys
import xml.etree.ElementTree as ET


GENERATED_PROJECT_PATHS = [
    'NotchX.xcodeproj/project.pbxproj',
    'NotchX.xcodeproj/xcshareddata/xcschemes/NotchX.xcscheme',
    'NotchX.xcodeproj/project.xcworkspace/contents.xcworkspacedata',
]


def stale_generated_project_paths(root):
    # Generate in an isolated tree so a failed check never rewrites reviewed files.
    with tempfile.TemporaryDirectory(prefix='notchx-project-check-') as temp:
        target = Path(temp)
        (target/'scripts').mkdir()
        shutil.copy2(root/'scripts/generate-xcode-project.py', target/'scripts/generate-xcode-project.py')
        for folder in ['App', 'Tests']:
            for source in (root/folder).rglob('*.swift'):
                dest = target/source.relative_to(root)
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.touch()
        subprocess.run([sys.executable, str(target/'scripts/generate-xcode-project.py')], check=True, stdout=subprocess.DEVNULL)
        return [path for path in GENERATED_PROJECT_PATHS
                if not (root/path).exists() or (root/path).read_bytes() != (target/path).read_bytes()]


def obsolete_source_paths(root):
    for old in ['Package.swift', 'Sources', 'Vendor/NotchKit', 'Tests/NotchXAppTests', 'ExtensionHost', 'Extensions']:
        path = root / old
        if not path.exists() and not path.is_symlink():
            continue
        if old == 'Vendor/NotchKit' and path.is_dir() and not path.is_symlink():
            # SwiftPM leaves ignored workspace metadata behind after source removal.
            # Exempt only that real directory, not arbitrary ignored/untracked files
            # or symlinks. Use the filesystem so source archives need no Git index.
            if all(child.name == '.swiftpm' and child.is_dir() and not child.is_symlink()
                   for child in path.iterdir()):
                continue
        yield old


def self_test():
    import unittest

    class ObsoleteSourceTests(unittest.TestCase):
        def setUp(self):
            self.temp = tempfile.TemporaryDirectory(prefix='notchx-inventory-test-')
            self.addCleanup(self.temp.cleanup)
            self.root = Path(self.temp.name)
            self.vendor = self.root / 'Vendor/NotchKit'

        def test_cache_only_source_archive_passes_without_changing_cache(self):
            cache = self.vendor / '.swiftpm/xcode/package.xcworkspace/contents.xcworkspacedata'
            cache.parent.mkdir(parents=True)
            cache.write_text('workspace metadata')
            self.assertEqual(list(obsolete_source_paths(self.root)), [])
            self.assertEqual(cache.read_text(), 'workspace metadata')

        def test_missing_and_empty_vendor_pass(self):
            self.assertEqual(list(obsolete_source_paths(self.root)), [])
            self.vendor.mkdir(parents=True)
            self.assertEqual(list(obsolete_source_paths(self.root)), [])

        def test_restored_source_alongside_cache_is_rejected(self):
            (self.vendor / '.swiftpm').mkdir(parents=True)
            source = self.vendor / 'Sources/NotchKit/NotchKit.swift'
            source.parent.mkdir(parents=True)
            source.write_text('// restored obsolete source')
            self.assertEqual(list(obsolete_source_paths(self.root)), ['Vendor/NotchKit'])

        def test_other_files_and_directories_are_rejected(self):
            self.vendor.mkdir(parents=True)
            for name in ['Package.swift', 'NotchKit.swift', '.DS_Store', '.swiftpm']:
                with self.subTest(name=name):
                    path = self.vendor / name
                    path.touch()
                    self.assertEqual(list(obsolete_source_paths(self.root)), ['Vendor/NotchKit'])
                    path.unlink()
            (self.vendor / '.build').mkdir()
            self.assertEqual(list(obsolete_source_paths(self.root)), ['Vendor/NotchKit'])

        def test_symlinks_are_rejected_even_when_broken(self):
            self.vendor.mkdir(parents=True)
            (self.vendor / '.swiftpm').symlink_to(self.root / 'missing', target_is_directory=True)
            self.assertEqual(list(obsolete_source_paths(self.root)), ['Vendor/NotchKit'])
            shutil.rmtree(self.vendor)
            self.vendor.symlink_to(self.root / 'missing', target_is_directory=True)
            self.assertEqual(list(obsolete_source_paths(self.root)), ['Vendor/NotchKit'])

        def test_other_obsolete_roots_still_rejected(self):
            for old in ['Package.swift', 'Sources', 'Tests/NotchXAppTests', 'ExtensionHost', 'Extensions']:
                with self.subTest(old=old):
                    path = self.root / old
                    path.mkdir(parents=True)
                    self.assertIn(old, obsolete_source_paths(self.root))

    class WorkspaceMetadataTests(unittest.TestCase):
        def setUp(self):
            self.temp = tempfile.TemporaryDirectory(prefix='notchx-workspace-test-')
            self.addCleanup(self.temp.cleanup)
            self.root = Path(self.temp.name)
            source_root = Path(__file__).resolve().parent.parent
            (self.root/'scripts').mkdir()
            shutil.copy2(source_root/'scripts/generate-xcode-project.py', self.root/'scripts/generate-xcode-project.py')
            shutil.copy2(source_root/'.gitignore', self.root/'.gitignore')
            for folder in ['App', 'Tests']:
                (self.root/folder).mkdir()
                (self.root/folder/'Example.swift').touch()
            self.workspace = self.root/GENERATED_PROJECT_PATHS[2]

        def generate(self):
            subprocess.run([sys.executable, str(self.root/'scripts/generate-xcode-project.py')],
                           check=True, stdout=subprocess.DEVNULL)

        def test_ignores_user_state_but_keeps_shared_metadata(self):
            subprocess.run(['git', '-c', 'init.templateDir=', 'init', '-q', str(self.root)], check=True)
            cases = {
                'NotchX.xcodeproj/xcuserdata/owner.xcuserdatad/UserInterfaceState.xcuserstate': True,
                'NotchX.xcodeproj/project.xcworkspace/xcuserdata/owner.xcuserdatad/UserInterfaceState.xcuserstate': True,
                'Nested/Example.xcworkspace/xcuserdata/owner.xcuserdatad/xcschemes/User.xcscheme': True,
                GENERATED_PROJECT_PATHS[1]: False,
                GENERATED_PROJECT_PATHS[2]: False,
                'NotchX.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings': False,
                'Nested/Example.xcworkspace/contents.xcworkspacedata': False,
                'Nested/Example.xcworkspace/xcshareddata/xcschemes/Shared.xcscheme': False,
            }
            for path, ignored in cases.items():
                with self.subTest(path=path):
                    result = subprocess.run(['git', '-C', str(self.root), '-c', 'core.excludesFile=/dev/null',
                                             'check-ignore', '--no-index', '--quiet', path])
                    self.assertEqual(result.returncode, 0 if ignored else 1)

        def test_tracked_workspace_stays_clean_with_local_user_state(self):
            subprocess.run(['git', '-c', 'init.templateDir=', 'init', '-q', str(self.root)], check=True)
            self.generate()
            workspace_path = GENERATED_PROJECT_PATHS[2]
            subprocess.run(['git', '-C', str(self.root), 'add', '--', workspace_path], check=True)
            user_state = self.workspace.parent/'xcuserdata/owner.xcuserdatad/UserInterfaceState.xcuserstate'
            user_state.parent.mkdir(parents=True)
            user_state.write_bytes(b'existing local user state')
            self.generate()
            subprocess.run(['git', '-C', str(self.root), 'diff', '--exit-code', '--', workspace_path], check=True)
            untracked = subprocess.run(['git', '-C', str(self.root), '-c', 'core.excludesFile=/dev/null',
                                        'ls-files', '--others', '--exclude-standard', '--',
                                        'NotchX.xcodeproj/project.xcworkspace'],
                                       check=True, capture_output=True, text=True)
            self.assertEqual(untracked.stdout, '')
            self.assertEqual(user_state.read_bytes(), b'existing local user state')

        def test_generation_is_deterministic_and_preserves_existing_workspace_data(self):
            preserved = [
                self.workspace.parent/'xcuserdata/owner.xcuserdatad/UserInterfaceState.xcuserstate',
                self.workspace.parent/'xcshareddata/WorkspaceSettings.xcsettings',
            ]
            for path in preserved:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'existing workspace data\x00\xff')
            self.generate()
            first = {path: (self.root/path).read_bytes() for path in GENERATED_PROJECT_PATHS}
            self.generate()
            self.assertEqual(first, {path: (self.root/path).read_bytes() for path in GENERATED_PROJECT_PATHS})
            workspace = ET.parse(self.workspace).getroot()
            self.assertEqual(workspace.tag, 'Workspace')
            self.assertEqual(workspace.get('version'), '1.0')
            self.assertEqual([element.attrib for element in workspace], [{'location': 'self:'}])
            self.assertEqual([element.tag for element in workspace], ['FileRef'])
            for path in preserved:
                self.assertEqual(path.read_bytes(), b'existing workspace data\x00\xff')

        def test_generation_check_rejects_missing_or_changed_workspace_without_rewriting(self):
            self.generate()
            self.assertEqual(stale_generated_project_paths(self.root), [])
            self.workspace.unlink()
            self.assertEqual(stale_generated_project_paths(self.root), [GENERATED_PROJECT_PATHS[2]])
            self.assertFalse(self.workspace.exists())
            self.workspace.write_text('changed workspace')
            self.assertEqual(stale_generated_project_paths(self.root), [GENERATED_PROJECT_PATHS[2]])
            self.assertEqual(self.workspace.read_text(), 'changed workspace')

    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(case)
                               for case in [ObsoleteSourceTests, WorkspaceMetadataTests])
    result = unittest.TextTestRunner().run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)


if '--self-test' in sys.argv:
    self_test()

root = Path(__file__).resolve().parent.parent
paths = GENERATED_PROJECT_PATHS
if stale_generated_project_paths(root):
    sys.exit('Native project is stale; run python3 scripts/generate-xcode-project.py and review the diff.')
# Validate launch/test semantics independently of generator output equality.
scheme = ET.parse(root/paths[1]).getroot()
launch = scheme.find("./LaunchAction/BuildableProductRunnable/BuildableReference")
if launch is None or launch.get("BuildableName") != "NotchX.app":
    sys.exit("Shared scheme must run NotchX.app.")
if launch.get("ReferencedContainer") != "container:NotchX.xcodeproj":
    sys.exit("Shared scheme references the wrong project.")
project = (root/paths[0]).read_text()
target_id = re.escape(launch.get("BlueprintIdentifier", ""))
if not re.search(r'"' + target_id + r'" = \{\s*"isa" = "PBXNativeTarget";', project):
    sys.exit("Run scheme references a missing native target.")
test_action = scheme.find("./TestAction")
if test_action is None or test_action.get("shouldUseLaunchSchemeArgsEnv") != "NO":
    sys.exit("Tests must use their isolated environment.")
test_flags = {v.get("key"): v.get("value") for v in test_action.findall("./EnvironmentVariables/EnvironmentVariable") if v.get("isEnabled") == "YES"}
if test_flags.get("NOTCHX_UNIT_TEST_HOST") != "1":
    sys.exit("Hosted tests must suppress normal application startup.")
deployment_targets = re.findall(r'"MACOSX_DEPLOYMENT_TARGET" = "([^"]+)";', project)
if not deployment_targets or set(deployment_targets) != {'26.0'}:
    sys.exit("All native targets must require macOS 26.0.")
if scheme.find("./LaunchAction/EnvironmentVariables/EnvironmentVariable[@key='NOTCHX_UNIT_TEST_HOST']") is not None:
    sys.exit("Normal Run must not enable the unit-test host flag.")
for old in obsolete_source_paths(root):
    sys.exit(f'Obsolete app/runtime source remains: {old}')
files = list((root/'App').rglob('*.swift'))
for path in files:
    if re.search(r'^\s*import\s+(NotchXCore|NotchXBuiltinPlugins|NotchKit)\b', path.read_text(), re.MULTILINE):
        sys.exit(f'Native app must not link the compatibility host/runtime: {path}')
entries = [p for p in files if '@main' in p.read_text()]
if len(entries) != 1:
    sys.exit(f'Expected exactly one native app entry point, found {entries}')
for path in (root/'App/Resources').rglob('*'):
    if path.name in ['node_modules', 'BundledExtensions'] or path.suffix in ['.mjs', '.cjs']:
        sys.exit(f'JavaScript extension asset present: {path}')
framework = root/'App/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework'
if not (framework/'Versions/Current').is_symlink() or not (framework/'MediaRemoteAdapter').is_symlink():
    sys.exit('Media adapter framework symlinks must be preserved.')
for file in [framework/'Versions/A/MediaRemoteAdapter', framework.parent/'mediaremote-adapter.pl']:
    if not file.stat().st_mode & 0o111:
        sys.exit(f'Media helper executable mode missing: {file}')
print(f'Native project inventory matches {len(files)} App Swift sources; one host and intact media resources.')
