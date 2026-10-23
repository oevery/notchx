#!/usr/bin/env python3
"""Verify checked-in project is current and source/resource ownership is native-only."""
from pathlib import Path
import subprocess
import tempfile
import shutil
import re
import json
import hashlib
import sys
import xml.etree.ElementTree as ET


GENERATED_PROJECT_PATHS = [
    'NotchX.xcodeproj/project.pbxproj',
    'NotchX.xcodeproj/xcshareddata/xcschemes/NotchX.xcscheme',
    'NotchX.xcodeproj/project.xcworkspace/contents.xcworkspacedata',
    'TestPlans/Core.xctestplan',
    'TestPlans/DesktopUI.xctestplan',
]

def validate_media_adapter(root):
    manifest = json.loads((root/'Config/MediaRemoteAdapter.json').read_text())
    base = 'App/Resources/MediaRemoteAdapter/'
    framework = base + 'MediaRemoteAdapter.framework/'
    required = {base + 'mediaremote-adapter.pl', framework + 'Versions/A/MediaRemoteAdapter',
                framework + 'Versions/A/Resources/Info.plist', framework + 'Versions/A/_CodeSignature/CodeResources',
                'Licenses/MediaRemoteAdapter-BSD-3-Clause.txt'}
    if (manifest.get('repository') != 'https://github.com/ungive/mediaremote-adapter'
        or not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', manifest.get('tag', ''))
        or not re.fullmatch(r'[0-9a-f]{40}', manifest.get('commit', ''))
        or set(manifest.get('sha256', {})) != required):
        raise ValueError('MediaRemoteAdapter provenance must pin source and every payload/license checksum.')
    for relative, expected in manifest['sha256'].items():
        if hashlib.sha256((root/relative).read_bytes()).hexdigest() != expected:
            raise ValueError(f'MediaRemoteAdapter checksum mismatch: {relative}')
    for relative, target in {'Versions/Current': 'A', 'Resources': 'Versions/Current/Resources',
                             'MediaRemoteAdapter': 'Versions/Current/MediaRemoteAdapter'}.items():
        link = root/framework/relative
        if not link.is_symlink() or str(link.readlink()) != target or not link.exists():
            raise ValueError(f'MediaRemoteAdapter framework link mismatch: {relative}')

def validate_test_selection(root, name, arguments):
    if name not in ['Core', 'DesktopUI']:
        raise ValueError('Unknown test plan')
    groups = {plan: set(json.loads((root/f'TestPlans/{plan}.xctestplan').read_text())['testTargets'][0]['selectedTests'])
              for plan in ['Core', 'DesktopUI']}
    forbidden = {'-testPlan', '-xctestrun', '-project', '-workspace', '-scheme', '-target', '-configuration'}
    for argument in arguments:
        if argument.split('=')[0] in forbidden or argument.startswith(('NOTCHX_DESKTOP_UI=', 'NOTCHX_UNIT_TEST_HOST=')):
            raise ValueError(f'Test entry cannot override the host or plan: {argument}')
        if argument.startswith('-only-testing:'):
            selector = argument.split(':', 1)[1].removesuffix('()')
            prefix = 'NotchXTests/'
            if not selector.startswith(prefix):
                raise ValueError('Select a suite or method inside NotchXTests')
            selector = selector[len(prefix):]
            def matches(value):
                value = value.removesuffix('()')
                return value == selector or value.startswith(selector+'/')
            if not any(matches(test) for test in groups[name]):
                raise ValueError(f'No {name} test matches {argument}; desktop tests require --ui')
            other = 'DesktopUI' if name == 'Core' else 'Core'
            if any(matches(test) for test in groups[other]):
                raise ValueError(f'Mixed suite: select individual {name} methods instead of overriding the plan')


def stale_generated_project_paths(root):
    # Generate in an isolated tree so a failed check never rewrites reviewed files.
    with tempfile.TemporaryDirectory(prefix='notchx-project-check-') as temp:
        target = Path(temp)
        (target/'scripts').mkdir()
        (target/'TestPlans').mkdir()
        shutil.copy2(root/'TestPlans/Groups.json', target/'TestPlans/Groups.json')
        shutil.copy2(root/'scripts/generate-xcode-project.py', target/'scripts/generate-xcode-project.py')
        for folder in ['App', 'Tests']:
            for source in (root/folder).rglob('*.swift'):
                dest = target/source.relative_to(root)
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, dest)
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

    class MediaAdapterTests(unittest.TestCase):
        def test_payload_license_and_manifest_mutations_are_rejected(self):
            source = Path(__file__).resolve().parent.parent
            with tempfile.TemporaryDirectory(prefix='notchx-media-check-') as temporary:
                root = Path(temporary)
                for directory in ['Config', 'Licenses', 'App/Resources/MediaRemoteAdapter']:
                    shutil.copytree(source/directory, root/directory, symlinks=True)
                validate_media_adapter(root)
                manifest_path = root/'Config/MediaRemoteAdapter.json'
                manifest = json.loads(manifest_path.read_text())
                for relative in manifest['sha256']:
                    file = root/relative
                    original = file.read_bytes()
                    file.chmod(file.stat().st_mode | 0o200)
                    file.write_bytes(original + b'changed')
                    with self.subTest(file=relative), self.assertRaises(ValueError):
                        validate_media_adapter(root)
                    file.write_bytes(original)
                del manifest['sha256']['App/Resources/MediaRemoteAdapter/mediaremote-adapter.pl']
                manifest_path.write_text(json.dumps(manifest))
                with self.assertRaises(ValueError):
                    validate_media_adapter(root)
                shutil.copy2(source/'Config/MediaRemoteAdapter.json', manifest_path)
                link = root/'App/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework/Versions/Current'
                link.unlink()
                link.symlink_to('missing')
                with self.assertRaises(ValueError):
                    validate_media_adapter(root)

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
            (self.root/'Tests/Example.swift').write_text('final class ExampleTests: XCTestCase {\n    func testCore() {}\n    @MainActor func testWindow() {}\n}\n')
            (self.root/'TestPlans').mkdir()
            (self.root/'TestPlans/Groups.json').write_text(json.dumps({
                'coreSuites': [], 'desktopUISuites': [],
                'mixedSuites': {'ExampleTests': ['testCore']}}))
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

        def test_test_plans_partition_methods_and_require_explicit_desktop_opt_in(self):
            self.generate()
            selections = {}
            for name, allowed in [('Core', '0'), ('DesktopUI', '1')]:
                plan = json.loads((self.root/f'TestPlans/{name}.xctestplan').read_text())
                selections[name] = plan['testTargets'][0]['selectedTests']
                flags = {v['key']: v['value'] for v in plan['defaultOptions']['environmentVariableEntries']}
                self.assertEqual(flags['NOTCHX_UNIT_TEST_HOST'], '1')
                self.assertEqual(flags['NOTCHX_DESKTOP_UI'], allowed)
                self.assertNotIn('skippedTests', plan['testTargets'][0])
            self.assertEqual(selections, {'Core': ['ExampleTests/testCore()'], 'DesktopUI': ['ExampleTests/testWindow()']})
            source = self.root/'Tests/Example.swift'
            source.write_text(source.read_text().replace('    func testCore()', '    func testNewWindow() {}\n    func testCore()'))
            self.generate()
            plan = json.loads((self.root/'TestPlans/DesktopUI.xctestplan').read_text())
            self.assertIn('ExampleTests/testNewWindow()', plan['testTargets'][0]['selectedTests'])

        def test_unknown_suites_and_stale_or_duplicate_classifications_fail_closed(self):
            path = self.root/'TestPlans/Groups.json'
            for groups in [
                {'coreSuites': [], 'desktopUISuites': [], 'mixedSuites': {}},
                {'coreSuites': ['ExampleTests'], 'desktopUISuites': ['ExampleTests'], 'mixedSuites': {}},
                {'coreSuites': [], 'desktopUISuites': [], 'mixedSuites': {'ExampleTests': ['testGone']}},
            ]:
                path.write_text(json.dumps(groups))
                result = subprocess.run([sys.executable, str(self.root/'scripts/generate-xcode-project.py')], capture_output=True)
                self.assertNotEqual(result.returncode, 0)

        def test_selection_cannot_bypass_desktop_opt_in(self):
            self.generate()
            validate_test_selection(self.root, 'Core', ['-only-testing:NotchXTests/ExampleTests/testCore'])
            validate_test_selection(self.root, 'DesktopUI', ['-only-testing:NotchXTests/ExampleTests/testWindow'])
            for arguments in [
                ['-only-testing:NotchXTests/ExampleTests/testWindow'],
                ['-only-testing:NotchXTests/ExampleTests'],
                ['-only-testing:OtherTests/testCore'],
                ['-configuration', 'Release'], ['-testPlan', 'DesktopUI'],
                ['-xctestrun', 'other.xctestrun'], ['NOTCHX_DESKTOP_UI=1'],
            ]:
                with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                    validate_test_selection(self.root, 'Core', arguments)

    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(case)
                               for case in [ObsoleteSourceTests, WorkspaceMetadataTests, MediaAdapterTests])
    result = unittest.TextTestRunner().run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)


if '--self-test' in sys.argv:
    self_test()

root = Path(__file__).resolve().parent.parent
if len(sys.argv) >= 3 and sys.argv[1] == '--test-selection':
    try:
        validate_test_selection(root, sys.argv[2], sys.argv[3:])
    except (ValueError, KeyError, OSError) as error:
        sys.exit(str(error))
    sys.exit(0)
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
plans = test_action.findall("./TestPlans/TestPlanReference")
if {p.get('reference') for p in plans} != {'container:TestPlans/Core.xctestplan', 'container:TestPlans/DesktopUI.xctestplan'}:
    sys.exit('Shared scheme must expose Core and DesktopUI test plans.')
if [p.get('reference') for p in plans if p.get('default') == 'YES'] != ['container:TestPlans/Core.xctestplan']:
    sys.exit('Default Xcode testing must use Core, never DesktopUI.')
selections = {}
for name in ['Core', 'DesktopUI']:
    plan = json.loads((root/f'TestPlans/{name}.xctestplan').read_text())
    flags = {entry['key']: entry['value'] for entry in plan['defaultOptions']['environmentVariableEntries'] if entry.get('enabled', True)}
    if flags.get('NOTCHX_UNIT_TEST_HOST') != '1':
        sys.exit('Hosted tests must suppress normal application startup in both plans.')
    if flags.get('NOTCHX_DESKTOP_UI') != ('1' if name == 'DesktopUI' else '0'):
        sys.exit('Only the explicit DesktopUI plan may enable desktop interaction.')
    targets = plan['testTargets']
    if len(targets) != 1 or targets[0]['target']['name'] != 'NotchXTests' or targets[0].get('enabled', True) is not True:
        sys.exit('Both plans must run the real native test target.')
    selections[name] = set(targets[0].get('selectedTests', []))
    if not selections[name] or targets[0].get('skippedTests'):
        sys.exit('Each plan must explicitly select its tests.')
if selections['Core'] & selections['DesktopUI']:
    sys.exit('Core and DesktopUI must not overlap.')
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
try:
    validate_media_adapter(root)
except (ValueError, KeyError, OSError) as error:
    sys.exit(str(error))
if not (framework/'Versions/Current').is_symlink() or not (framework/'MediaRemoteAdapter').is_symlink():
    sys.exit('Media adapter framework symlinks must be preserved.')
for file in [framework/'Versions/A/MediaRemoteAdapter', framework.parent/'mediaremote-adapter.pl']:
    if not file.stat().st_mode & 0o111:
        sys.exit(f'Media helper executable mode missing: {file}')
print(f'Native project inventory matches {len(files)} App Swift sources; one host and intact media resources.')
