#!/usr/bin/env python3
"""Write Eden.xcodeproj with stable object ids and no build dependencies.

The same approach as Mulberry's: the project is generated, never edited in
Xcode, so it stays readable in review. Run it after adding or removing a
source file: python3 apps/ios/scripts/generate-project.py
"""
from pathlib import Path
import hashlib
import json
import os

root = Path(__file__).resolve().parents[1]
version = (root.parent.parent / 'VERSION').read_text().strip()
objects = {}


def oid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def add(key_name, **fields):
    key = oid(key_name)
    objects[key] = fields
    return key


def quote(value, depth=0):
    indent = '\t' * depth
    if isinstance(value, dict):
        lines = [f'{indent}\t{quote(k)} = {quote(v, depth + 1)};' for k, v in value.items()]
        return '{\n' + '\n'.join(lines) + '\n' + indent + '}'
    if isinstance(value, list):
        return '(' + ', '.join(quote(v, depth) for v in value) + ')'
    return json.dumps(str(value))


def file(path, kind):
    return add(path, isa='PBXFileReference', lastKnownFileType=kind, path=path, sourceTree='<group>')


sources = sorted(root.glob('Sources/**/*.swift'))
refs, builds = [], []
for source in sources:
    relative = os.path.relpath(source, root)
    reference = file(relative, 'sourcecode.swift')
    refs.append(reference)
    builds.append(add('build:' + relative, isa='PBXBuildFile', fileRef=reference))

# The icon is an Icon Composer document (scripts/make-icon.sh writes it from
# the Mac app's icon script, so both draw the one mark).
icon_ref = file('Resources/AppIcon.icon', 'folder.iconcomposer.icon')
icon_build = add('icon-build', isa='PBXBuildFile', fileRef=icon_ref)
privacy_ref = file('Resources/PrivacyInfo.xcprivacy', 'text.xml')
privacy_build = add('privacy-build', isa='PBXBuildFile', fileRef=privacy_ref)
config_ref = file('Configuration/Base.xcconfig', 'text.xcconfig')
plist_ref = file('Configuration/Info.plist', 'text.plist.xml')
entitlements_ref = file('Configuration/Eden.entitlements', 'text.plist.entitlements')

# The unit tests (Swift Testing), run inside the app as their host.
test_refs, test_builds = [], []
for source in sorted(root.glob('Tests/**/*.swift')):
    relative = os.path.relpath(source, root)
    reference = file(relative, 'sourcecode.swift')
    test_refs.append(reference)
    test_builds.append(add('test-build:' + relative, isa='PBXBuildFile', fileRef=reference))

product = add('product', isa='PBXFileReference', explicitFileType='wrapper.application', path='Eden.app', sourceTree='BUILT_PRODUCTS_DIR')
test_product = add('test-product', isa='PBXFileReference', explicitFileType='wrapper.cfbundle', path='EdenTests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
products = add('products', isa='PBXGroup', name='Products', children=[product, test_product], sourceTree='<group>')
main = add('main', isa='PBXGroup', children=refs + test_refs + [icon_ref, privacy_ref, config_ref, plist_ref, entitlements_ref, products], sourceTree='<group>')

sources_phase = add('sources-phase', isa='PBXSourcesBuildPhase', buildActionMask='2147483647', files=builds, runOnlyForDeploymentPostprocessing='0')
resources_phase = add('resources-phase', isa='PBXResourcesBuildPhase', buildActionMask='2147483647', files=[icon_build, privacy_build], runOnlyForDeploymentPostprocessing='0')
frameworks_phase = add('frameworks-phase', isa='PBXFrameworksBuildPhase', buildActionMask='2147483647', files=[], runOnlyForDeploymentPostprocessing='0')

project_configs, target_configs = [], []
for mode, debug in [('Debug', True), ('Release', False)]:
    project_configs.append(add('project-' + mode, isa='XCBuildConfiguration', name=mode, buildSettings={
        'SDKROOT': 'iphoneos', 'IPHONEOS_DEPLOYMENT_TARGET': '27.0', 'CLANG_ENABLE_MODULES': 'YES',
        'SWIFT_VERSION': '6.0', 'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if debug else '-O',
        'SWIFT_COMPILATION_MODE': 'singlefile' if debug else 'wholemodule',
        'SWIFT_DEFAULT_ACTOR_ISOLATION': 'MainActor',
        'DEBUG_INFORMATION_FORMAT': 'dwarf' if debug else 'dwarf-with-dsym',
        'ENABLE_TESTABILITY': 'YES' if debug else 'NO', 'ONLY_ACTIVE_ARCH': 'YES' if debug else 'NO',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG' if debug else '',
    }))
    target_configs.append(add('target-' + mode, isa='XCBuildConfiguration', name=mode, baseConfigurationReference=config_ref, buildSettings={
        'PRODUCT_NAME': 'Eden', 'PRODUCT_BUNDLE_IDENTIFIER': '$(EDEN_BUNDLE_IDENTIFIER)',
        'MARKETING_VERSION': version, 'CURRENT_PROJECT_VERSION': '1',
        'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon',
        'INFOPLIST_FILE': 'Configuration/Info.plist', 'GENERATE_INFOPLIST_FILE': 'NO',
        'CODE_SIGN_ENTITLEMENTS': 'Configuration/Eden.entitlements',
        'TARGETED_DEVICE_FAMILY': '1,2', 'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator',
        'SUPPORTS_MACCATALYST': 'NO', 'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD': 'NO',
        'SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD': 'NO',
        'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/Frameworks',
    }))

test_configs = []
for mode, debug in [('Debug', True), ('Release', False)]:
    test_configs.append(add('test-' + mode, isa='XCBuildConfiguration', name=mode, baseConfigurationReference=config_ref, buildSettings={
        'PRODUCT_NAME': 'EdenTests', 'PRODUCT_BUNDLE_IDENTIFIER': '$(EDEN_BUNDLE_IDENTIFIER).tests',
        'MARKETING_VERSION': version, 'CURRENT_PROJECT_VERSION': '1', 'GENERATE_INFOPLIST_FILE': 'YES',
        'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/Eden.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Eden', 'BUNDLE_LOADER': '$(TEST_HOST)',
        'TARGETED_DEVICE_FAMILY': '1,2', 'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator', 'SUPPORTS_MACCATALYST': 'NO',
        'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/Frameworks @loader_path/Frameworks',
    }))

project_list = add('project-configs', isa='XCConfigurationList', buildConfigurations=project_configs, defaultConfigurationIsVisible='0', defaultConfigurationName='Release')
target_list = add('target-configs', isa='XCConfigurationList', buildConfigurations=target_configs, defaultConfigurationIsVisible='0', defaultConfigurationName='Release')
target = add('app-target', isa='PBXNativeTarget', name='Eden', productName='Eden', productType='com.apple.product-type.application',
             productReference=product, buildConfigurationList=target_list,
             buildPhases=[sources_phase, frameworks_phase, resources_phase], dependencies=[], buildRules=[])
test_list = add('test-configs', isa='XCConfigurationList', buildConfigurations=test_configs, defaultConfigurationIsVisible='0', defaultConfigurationName='Release')
test_sources_phase = add('test-sources-phase', isa='PBXSourcesBuildPhase', buildActionMask='2147483647', files=test_builds, runOnlyForDeploymentPostprocessing='0')
test_frameworks_phase = add('test-frameworks-phase', isa='PBXFrameworksBuildPhase', buildActionMask='2147483647', files=[], runOnlyForDeploymentPostprocessing='0')
test_resources_phase = add('test-resources-phase', isa='PBXResourcesBuildPhase', buildActionMask='2147483647', files=[], runOnlyForDeploymentPostprocessing='0')
test_proxy = add('test-proxy', isa='PBXContainerItemProxy', containerPortal=oid('project'), proxyType='1', remoteGlobalIDString=target, remoteInfo='Eden')
test_dependency = add('test-dependency', isa='PBXTargetDependency', target=target, targetProxy=test_proxy)
test_target = add('test-target', isa='PBXNativeTarget', name='EdenTests', productName='EdenTests', productType='com.apple.product-type.bundle.unit-test',
                  productReference=test_product, buildConfigurationList=test_list,
                  buildPhases=[test_sources_phase, test_frameworks_phase, test_resources_phase], dependencies=[test_dependency], buildRules=[])
project = add('project', isa='PBXProject', attributes={'LastUpgradeCheck': '2720', 'BuildIndependentTargetsInParallel': '1',
                                                    'TargetAttributes': {test_target: {'TestTargetID': target}}},
              buildConfigurationList=project_list, compatibilityVersion='Xcode 14.0', developmentRegion='en',
              knownRegions=['en', 'Base'], mainGroup=main, productRefGroup=products, projectDirPath='', projectRoot='', targets=[target, test_target])

folder = root / 'Eden.xcodeproj'
folder.mkdir(exist_ok=True)
(folder / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + quote({'archiveVersion': '1', 'classes': {}, 'objectVersion': '56', 'objects': objects, 'rootObject': project}) + '\n')
schemes = folder / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Eden.app" BlueprintName="Eden" ReferencedContainer="container:Eden.xcodeproj"/>'
test_ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="EdenTests.xctest" BlueprintName="EdenTests" ReferencedContainer="container:Eden.xcodeproj"/>'
(schemes / 'Eden.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2720" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{test_ref}</BuildActionEntry></BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test_ref}</TestableReference></Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(folder)
