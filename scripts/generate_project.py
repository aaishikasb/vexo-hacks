#!/usr/bin/env python3
"""Generate the app project using only Python's standard library."""
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# Preserve Xcode's local signing selection when regenerating source membership.
existing = ROOT / "Voca.xcodeproj/project.pbxproj"
if existing.exists():
    match = re.search(r'"?DEVELOPMENT_TEAM"?\s*=\s*"?([A-Z0-9]+)"?\s*;', existing.read_text())
    if match:
        local = ROOT / ".local/Signing.xcconfig"
        local.parent.mkdir(exist_ok=True)
        if not local.exists():
            local.write_text("DEVELOPMENT_TEAM = " + match.group(1) + "\n")
objects = {}
def obj(key, **fields):
    ident = hashlib.sha256(key.encode()).hexdigest()[:24].upper()
    objects[ident] = fields
    return ident
def render(value):
    if isinstance(value, dict):
        return '{\n' + ''.join(f'{json.dumps(k)} = {render(v)};\n' for k, v in value.items()) + '}'
    if isinstance(value, list):
        return '(' + ', '.join(render(v) for v in value) + ')'
    return json.dumps(value)

files, compiled, resources = [], [], []
for path in sorted((ROOT / 'Voca').rglob('*.swift')):
    name = str(path.relative_to(ROOT))
    ref = obj(name, isa='PBXFileReference', lastKnownFileType='sourcecode.swift', path=name, sourceTree='<group>')
    files.append(ref)
    compiled.append(obj(name + '-build', isa='PBXBuildFile', fileRef=ref))
packages, products, linked = [], [], []
for name, url, version, names in [
    ('litert', 'https://github.com/google-ai-edge/LiteRT-LM', '0.19.1', ['LiteRTLM']),
    ('meta', 'https://github.com/facebook/meta-wearables-dat-ios', '1.0.1', ['MWDATCore', 'MWDATCamera'])
]:
    package = obj(name, isa='XCRemoteSwiftPackageReference', repositoryURL=url, requirement={'kind':'exactVersion', 'version': version})
    packages.append(package)
    for product_name in names:
        product = obj(product_name, isa='XCSwiftPackageProductDependency', package=package, productName=product_name)
        products.append(product)
        linked.append(obj(product_name + '-link', isa='PBXBuildFile', productRef=product))
if (ROOT / 'Packages/VocaCore/Package.swift').exists():
    packages.append(obj('core', isa='XCLocalSwiftPackageReference', relativePath='Packages/VocaCore'))
    product = obj('VocaCore', isa='XCSwiftPackageProductDependency', productName='VocaCore')
    products.append(product)
    linked.append(obj('core-link', isa='PBXBuildFile', productRef=product))
for path in sorted((ROOT / 'Resources').rglob('*.json')):
    name = str(path.relative_to(ROOT))
    ref = obj(name, isa='PBXFileReference', lastKnownFileType='text.json', path=name, sourceTree='<group>')
    files.append(ref)
    resources.append(obj(name + '-build', isa='PBXBuildFile', fileRef=ref))
config = obj('config', isa='PBXFileReference', lastKnownFileType='text.xcconfig', path='config/Build.xcconfig', sourceTree='<group>')
app = obj('app', isa='PBXFileReference', explicitFileType='wrapper.application', path='Voca.app', sourceTree='BUILT_PRODUCTS_DIR')
product_group = obj('products', isa='PBXGroup', children=[app], name='Products', sourceTree='<group>')
group = obj('root', isa='PBXGroup', children=files+[config, product_group], sourceTree='<group>')
phases = [obj(kind, isa=kind, buildActionMask=2147483647, files=items, runOnlyForDeploymentPostprocessing=0) for kind, items in [('PBXSourcesBuildPhase', compiled), ('PBXFrameworksBuildPhase', linked), ('PBXResourcesBuildPhase', resources)]]
def configs(key, settings):
    configs = []
    for name in ['Debug', 'Release']:
        configs.append(obj(key+name, isa='XCBuildConfiguration', baseConfigurationReference=config, buildSettings={**settings, 'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if name == 'Debug' else '-O'}, name=name))
    return obj(key+'configs', isa='XCConfigurationList', buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
target = obj('target', isa='PBXNativeTarget', name='Voca', productName='Voca', productReference=app, productType='com.apple.product-type.application', buildConfigurationList=configs('target', {}), buildPhases=phases, buildRules=[], dependencies=[], packageProductDependencies=products)
project = obj('project', isa='PBXProject', attributes={'BuildIndependentTargetsInParallel':'YES', 'LastUpgradeCheck':'2720'}, buildConfigurationList=configs('project', {}), compatibilityVersion='Xcode 14.0', developmentRegion='en', knownRegions=['en','Base'], mainGroup=group, productRefGroup=product_group, projectDirPath='', projectRoot='', targets=[target], packageReferences=packages)
path = ROOT / 'Voca.xcodeproj'
path.mkdir(exist_ok=True)
(path / 'project.pbxproj').write_text('// !$*UTF8*$!\n'+render({'archiveVersion':1,'classes':{},'objectVersion':56,'objects':objects,'rootObject':project})+'\n')
scheme = path / 'xcshareddata/xcschemes'
scheme.mkdir(parents=True, exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Voca.app" BlueprintName="Voca" ReferencedContainer="container:Voca.xcodeproj"/>'
(scheme / 'Voca.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2720" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>\n''')
assert all(ref in objects for ref in phases + products + packages)
print('Generated Voca.xcodeproj; signing overrides belong in .local/Signing.xcconfig')
