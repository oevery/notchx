#!/usr/bin/env python3
"""Generate the checked-in, dependency-free native Xcode project.
Run after adding/removing Swift files. No XcodeGen or package download is needed.
"""
import hashlib
import json
import re
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

def test_groups(root):
    """Enumerate explicit XCTest methods; never default an unknown suite to Core."""
    suites = {}
    for source in sorted((root/'Tests').rglob('*.swift')):
        suite = None
        for line in source.read_text().splitlines():
            declaration = re.match(r'^final class (\w+): XCTestCase \{', line)
            if declaration:
                suite = declaration[1]
                if suite in suites:
                    raise ValueError(f'Duplicate test suite: {suite}')
                suites[suite] = []
            elif re.match(r'^(?:(?:private|final) )*(?:class|struct|enum|extension) ', line):
                suite = None
            method = re.match(r'^    (?:@\w+\s+)*func (test\w+)\(\)', line)
            if re.search(r'\bfunc\s+test\w+\(', line) and not method:
                raise ValueError(f'Unsupported XCTest declaration: {source.name}: {line}')
            if method:
                if suite is None:
                    raise ValueError(f'Unclassified XCTest declaration: {source.name}: {line}')
                if method[1] in suites[suite]:
                    raise ValueError(f'Duplicate test: {suite}/{method[1]}')
                suites[suite].append(method[1])
    groups = json.loads((root/'TestPlans/Groups.json').read_text())
    core, desktop, mixed = groups['coreSuites'], groups['desktopUISuites'], groups['mixedSuites']
    classified = core + desktop + list(mixed)
    if len(classified) != len(set(classified)) or set(classified) != set(suites):
        raise ValueError(f'Test groups must classify each suite exactly once; unknown: {set(suites)-set(classified)}; stale: {set(classified)-set(suites)}')
    result = {'Core': [], 'DesktopUI': []}
    for suite, methods in suites.items():
        if not methods:
            raise ValueError(f'Empty test suite: {suite}')
        safe = methods if suite in core else mixed.get(suite, [])
        if len(safe) != len(set(safe)) or not set(safe) <= set(methods):
            raise ValueError(f'Stale or duplicate Core method selection: {suite}')
        for method in methods:
            result['Core' if method in safe else 'DesktopUI'].append(f'{suite}/{method}()')
    return {name: sorted(methods) for name, methods in result.items()}

test_selections = test_groups(ROOT)
objects = {}
def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def add(key_name, isa, **values):
    key = ident(key_name)
    objects[key] = dict(isa=isa, **values)
    return key
def encode(value, level=0):
    indent = '\t' * level
    inner = '\t' * (level + 1)
    if isinstance(value, dict):
        return '{\n' + ''.join(f'{inner}{json.dumps(k)} = {encode(v, level+1)};\n' for k,v in value.items()) + indent + '}'
    if isinstance(value, list):
        return '(\n' + ''.join(f'{inner}{encode(v, level+1)},\n' for v in value) + indent + ')' if value else '()'
    return json.dumps(str(value))

def configs(name, extra):
    values = []
    for mode in ['Debug', 'Release']:
        settings = dict(SWIFT_VERSION='5.0', MACOSX_DEPLOYMENT_TARGET='26.0', SDKROOT='macosx',
                        CLANG_ENABLE_MODULES='YES', SWIFT_OPTIMIZATION_LEVEL='-Onone' if mode=='Debug' else '-O',
                        SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG' if mode=='Debug' else '',
                        ENABLE_TESTABILITY='YES' if mode=='Debug' else 'NO',
                        ONLY_ACTIVE_ARCH='YES' if mode=='Debug' else 'NO',
                        DEBUG_INFORMATION_FORMAT='dwarf' if mode=='Debug' else 'dwarf-with-dsym',
                        ENABLE_USER_SCRIPT_SANDBOXING='NO')
        settings.update(extra)
        base = dict(baseConfigurationReference=ident('signing-config')) if name == 'project' else {}
        values.append(add(name+mode, 'XCBuildConfiguration', name=mode, buildSettings=settings, **base))
    return add(name+'configs','XCConfigurationList',buildConfigurations=values,defaultConfigurationIsVisible='0',defaultConfigurationName='Debug')

app_product=add('app-product','PBXFileReference',explicitFileType='wrapper.application',path='NotchX.app',sourceTree='BUILT_PRODUCTS_DIR')
test_product=add('test-product','PBXFileReference',explicitFileType='wrapper.cfbundle',path='NotchXTests.xctest',sourceTree='BUILT_PRODUCTS_DIR')
products=add('products','PBXGroup',name='Products',children=[app_product,test_product],sourceTree='<group>')
groups=[]
phases={}
for folder in ['App','Tests']:
    refs=[]; builds=[]
    for path in sorted((ROOT/folder).rglob('*.swift')):
        rel=str(path.relative_to(ROOT))
        ref=add('file:'+rel,'PBXFileReference',lastKnownFileType='sourcecode.swift',path=rel,sourceTree='SOURCE_ROOT')
        refs.append(ref)
        builds.append(add('build:'+rel,'PBXBuildFile',fileRef=ref))
    groups.append(add('group:'+folder,'PBXGroup',name=folder,children=refs,sourceTree='<group>'))
    phases[folder]=add('sources:'+folder,'PBXSourcesBuildPhase',buildActionMask='2147483647',files=builds,runOnlyForDeploymentPostprocessing='0')
# A native dependency lets Xcode track sources, SDK, architecture and build settings.
# Do not recompile the bridge with an opaque swiftc invocation on every test run.
helper_product=add('helper-product','PBXFileReference',explicitFileType='compiled.mach-o.executable',path='NotchXAgentBridge',sourceTree='BUILT_PRODUCTS_DIR')
objects[products]['children'].append(helper_product)
helper_main=add('helper-main','PBXFileReference',lastKnownFileType='sourcecode.swift',path='Helpers/NotchXAgentBridge/main.swift',sourceTree='SOURCE_ROOT')
groups.append(add('helper-group','PBXGroup',name='Helpers',children=[helper_main],sourceTree='<group>'))
helper_sources=[add('helper-build:main','PBXBuildFile',fileRef=helper_main)]
for name in ['AgentHookWire', 'AgentUnixSocket', 'CodexHookMetadata']:
    helper_sources.append(add('helper-build:'+name,'PBXBuildFile',fileRef=ident('file:App/Modules/Agent/'+name+'.swift')))
helper_phase=add('helper-sources','PBXSourcesBuildPhase',buildActionMask='2147483647',files=helper_sources,runOnlyForDeploymentPostprocessing='0')
helper=add('helper-target','PBXNativeTarget',name='NotchXAgentBridge',productName='NotchXAgentBridge',productReference=helper_product,productType='com.apple.product-type.tool',buildConfigurationList=configs('helper',dict(PRODUCT_NAME='NotchXAgentBridge',PRODUCT_BUNDLE_IDENTIFIER='app.notchx.agent-bridge',SKIP_INSTALL='YES')),buildPhases=[helper_phase],buildRules=[],dependencies=[])
helper_proxy=add('helper-proxy','PBXContainerItemProxy',containerPortal=ident('project'),proxyType='1',remoteGlobalIDString=helper,remoteInfo='NotchXAgentBridge')
helper_dep=add('helper-dep','PBXTargetDependency',target=helper,targetProxy=helper_proxy)
resource_phase=add('native-resources','PBXShellScriptBuildPhase',name='Assemble native resources and agent bridge',buildActionMask='2147483647',files=[],inputPaths=['$(BUILT_PRODUCTS_DIR)/NotchXAgentBridge'],outputPaths=[],runOnlyForDeploymentPostprocessing='0',shellPath='/bin/bash',shellScript='set -euo pipefail\n/bin/bash "${SRCROOT}/scripts/build-native-components.sh"\n',alwaysOutOfDate='1')
app=add('app-target','PBXNativeTarget',name='NotchX',productName='NotchX',productReference=app_product,productType='com.apple.product-type.application',buildConfigurationList=configs('app',dict(PRODUCT_BUNDLE_IDENTIFIER='app.notchx',PRODUCT_NAME='NotchX',INFOPLIST_FILE='App/Info.plist',CODE_SIGN_ENTITLEMENTS='App/NotchX.entitlements',ENABLE_HARDENED_RUNTIME='YES',LD_RUNPATH_SEARCH_PATHS='$(inherited) @executable_path/../Frameworks')),buildPhases=[phases['App'],resource_phase],buildRules=[],dependencies=[helper_dep])
proxy=add('test-proxy','PBXContainerItemProxy',containerPortal=ident('project'),proxyType='1',remoteGlobalIDString=app,remoteInfo='NotchX')
dep=add('test-dep','PBXTargetDependency',target=app,targetProxy=proxy)
test=add('test-target','PBXNativeTarget',name='NotchXTests',productName='NotchXTests',productReference=test_product,productType='com.apple.product-type.bundle.unit-test',buildConfigurationList=configs('tests',dict(PRODUCT_BUNDLE_IDENTIFIER='app.notchx.native-tests',PRODUCT_NAME='NotchXTests',GENERATE_INFOPLIST_FILE='YES',TEST_HOST='$(BUILT_PRODUCTS_DIR)/NotchX.app/Contents/MacOS/NotchX',BUNDLE_LOADER='$(TEST_HOST)',LD_RUNPATH_SEARCH_PATHS='$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks')),buildPhases=[phases['Tests']],buildRules=[],dependencies=[dep])
signing_config=add('signing-config','PBXFileReference',lastKnownFileType='text.xcconfig',path='Config/Signing.xcconfig',sourceTree='SOURCE_ROOT')
version_config=add('version-config','PBXFileReference',lastKnownFileType='text.xcconfig',path='Config/Version.xcconfig',sourceTree='SOURCE_ROOT')
signing_group=add('signing-group','PBXGroup',name='Configuration',children=[signing_config,version_config],sourceTree='<group>')
main=add('main-group','PBXGroup',children=groups+[signing_group,products],sourceTree='<group>')
project=add('project','PBXProject',attributes={'BuildIndependentTargetsInParallel':'YES','LastUpgradeCheck':'1600'},buildConfigurationList=configs('project',{}),compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings='0',knownRegions=['en','zh-Hans','Base'],mainGroup=main,productRefGroup=products,projectDirPath='',projectRoot='',targets=[app,test,helper])
project_dir=ROOT/'NotchX.xcodeproj'; project_dir.mkdir(exist_ok=True)
(project_dir/'project.pbxproj').write_text('// !$*UTF8*$!\n'+encode(dict(archiveVersion='1',classes={},objectVersion='56',objects=objects,rootObject=project))+'\n')
workspace_dir=project_dir/'project.xcworkspace'; workspace_dir.mkdir(exist_ok=True)
(workspace_dir/'contents.xcworkspacedata').write_text('''<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>
''')
scheme_dir=project_dir/'xcshareddata/xcschemes'; scheme_dir.mkdir(parents=True,exist_ok=True)
def reference(target, product, name):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:NotchX.xcodeproj"/>'
app_ref=reference(app,'NotchX.app','NotchX')
(scheme_dir/'NotchX.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO"><TestPlans><TestPlanReference reference="container:TestPlans/Core.xctestplan" default="YES"/><TestPlanReference reference="container:TestPlans/DesktopUI.xctestplan"/></TestPlans></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
plan_dir=ROOT/'TestPlans'; plan_dir.mkdir(exist_ok=True)
for name, selection in test_selections.items():
    target={'target': {'containerPath': 'container:NotchX.xcodeproj', 'identifier': test, 'name': 'NotchXTests'},
            'selectedTests': selection}
    plan={'configurations': [{'id': str(uuid.uuid5(uuid.NAMESPACE_URL, 'app.notchx/tests/'+name)).upper(), 'name': name, 'options': {}}],
          'defaultOptions': {'environmentVariableEntries': [{'key': 'NOTCHX_UNIT_TEST_HOST', 'value': '1'},
                                {'key': 'NOTCHX_DESKTOP_UI', 'value': '1' if name == 'DesktopUI' else '0'},
                                {'key': 'NOTCHX_CAPTURE_TEST_IMAGES', 'value': '$(NOTCHX_CAPTURE_TEST_IMAGES)'}],
                             'targetForVariableExpansion': {'containerPath': 'container:NotchX.xcodeproj', 'identifier': app, 'name': 'NotchX'}},
          'testTargets': [target], 'version': 1}
    (plan_dir/(name+'.xctestplan')).write_text(json.dumps(plan, indent=2)+'\n')
print('Generated NotchX.xcodeproj and Core/DesktopUI test plans: '+', '.join(f'{name}={len(methods)}' for name, methods in test_selections.items()))
