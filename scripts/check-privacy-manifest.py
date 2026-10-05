#!/usr/bin/env python3
"""Check platform privacy declarations and optionally all four built app manifests.

This is a packaging regression guard, not Apple's signed-archive privacy report.
"""
import argparse
import plistlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = Path('Labstream/Shared/Resources/PrivacyInfo.xcprivacy')
TARGETS = ('Labstream', 'LabstreamMobile', 'LabstreamTV', 'LabstreamMac')
CATEGORY = 'NSPrivacyAccessedAPICategorySystemBootTime'
TV_MANIFEST = Path('Labstream/Platforms/tvOS/Resources/PrivacyInfo.xcprivacy')
TV_EXCEPTION = 'AA0000000000000000000090'
SHARED_GROUP = 'AA0000000000000000000006'
TV_GROUP = 'AA0000000000000000000064'
TV_TARGET = '08BB83012E40DA7982254087'
EXPECTED_ACCESSED = {
    CATEGORY: ['35F9.1'],
    'NSPrivacyAccessedAPICategoryUserDefaults': ['CA92.1'],
    'NSPrivacyAccessedAPICategoryFileTimestamp': ['DDA9.1'],
    'NSPrivacyAccessedAPICategoryDiskSpace': ['85F4.1'],
}
FUNCTIONALITY = 'NSPrivacyCollectedDataTypePurposeAppFunctionality'
PERSONALIZATION = 'NSPrivacyCollectedDataTypePurposeProductPersonalization'
EXPECTED_COLLECTION = {
    'NSPrivacyCollectedDataType' + name: [FUNCTIONALITY, PERSONALIZATION]
    for name in ('UserID', 'DeviceID', 'ProductInteraction')
} | {
    'NSPrivacyCollectedDataType' + name: [FUNCTIONALITY]
    for name in ('CustomerSupport', 'OtherDiagnosticData', 'PerformanceData', 'CrashData')
}



def read_manifest(path, target=None):
    with path.open('rb') as stream:
        data = plistlib.load(stream)
    if not isinstance(data, dict):
        raise ValueError(f'{path.name}: manifest must be a dictionary')
    accessed = data.get('NSPrivacyAccessedAPITypes', [])
    if not isinstance(accessed, list) or any(not isinstance(e, dict) for e in accessed):
        raise ValueError(f'{path.name}: malformed required-reason declarations')
    entries = [entry for entry in accessed
               if entry.get('NSPrivacyAccessedAPIType') == CATEGORY]
    if len(entries) != 1 or entries[0].get('NSPrivacyAccessedAPITypeReasons') != ['35F9.1']:
        raise ValueError(f'{path.name}: expected one SystemBootTime declaration with 35F9.1')
    api_types = [e.get('NSPrivacyAccessedAPIType') for e in accessed]
    if (len(api_types) != len(EXPECTED_ACCESSED)
            or any(kind not in EXPECTED_ACCESSED for kind in api_types)
            or len(set(api_types)) != len(api_types)
            or any(e.get('NSPrivacyAccessedAPITypeReasons') != EXPECTED_ACCESSED[e['NSPrivacyAccessedAPIType']]
                   for e in accessed)):
        raise ValueError(f'{path.name}: required-reason declarations differ from approved source contract')
    if data.get('NSPrivacyTracking') is not False or data.get('NSPrivacyTrackingDomains') != []:
        raise ValueError(f'{path.name}: tracking must be false with no tracking domains')
    expected = dict(EXPECTED_COLLECTION)
    if target == 'LabstreamTV':
        del expected['NSPrivacyCollectedDataTypeCrashData']
    actual = {}
    collected = data.get('NSPrivacyCollectedDataTypes', [])
    if not isinstance(collected, list) or any(not isinstance(e, dict) for e in collected):
        raise ValueError(f'{path.name}: malformed collected-data declarations')
    for entry in collected:
        kind = entry.get('NSPrivacyCollectedDataType')
        purposes = entry.get('NSPrivacyCollectedDataTypePurposes', [])
        if kind not in expected or kind in actual:
            raise ValueError(f'{path.name}: unexpected or duplicate collected data type')
        if (entry.get('NSPrivacyCollectedDataTypeLinked') is not True
                or entry.get('NSPrivacyCollectedDataTypeTracking') is not False
                or not isinstance(purposes, list)
                or any(not isinstance(p, str) for p in purposes)
                or len(purposes) != len(expected[kind])
                or set(purposes) != set(expected[kind])):
            raise ValueError(f'{path.name}: incorrect linked/tracking/purpose declaration for {kind}')
        actual[kind] = entry
    if set(actual) != set(expected):
        raise ValueError(f'{path.name}: collected data types differ from approved platform mapping')
    return data


def project_objects(project):
    """Extract top-level PBX objects, preserving nesting rather than matching inner braces."""
    clean = re.sub(r'/\*.*?\*/', '', project, flags=re.S)
    objects = {}
    for match in re.finditer(r'^\t\t([A-F0-9]{24})\s*=\s*\{', clean, re.M):
        depth, quoted, escaped = 1, False, False
        end = match.end()
        while end < len(clean) and depth:
            char = clean[end]
            if escaped:
                escaped = False
            elif quoted and char == '\\':
                escaped = True
            elif char == '"':
                quoted = not quoted
            elif not quoted:
                depth += (char == '{') - (char == '}')
            end += 1
        if depth or match[1] in objects:
            raise ValueError('Malformed or duplicate PBX object')
        objects[match[1]] = clean[match.end():end - 1]
    return objects


def check_source(root=ROOT):
    shared = read_manifest(root / MANIFEST)
    tv = read_manifest(root / TV_MANIFEST, 'LabstreamTV')
    expected_tv = dict(shared, NSPrivacyCollectedDataTypes=[
        e for e in shared['NSPrivacyCollectedDataTypes']
        if e['NSPrivacyCollectedDataType'] != 'NSPrivacyCollectedDataTypeCrashData'])
    if tv != expected_tv:
        raise ValueError('tvOS source must differ from shared source only by omitted CrashData')
    project = (root / 'Labstream.xcodeproj/project.pbxproj').read_text()
    objects = project_objects(project)
    for target in TARGETS:
        matching = [block for block in objects.values()
                    if re.search(r'\bisa\s*=\s*PBXNativeTarget;', block)
                    and re.search(rf'\bname\s*=\s*{target};', block)]
        if len(matching) != 1:
            raise ValueError(f'{target}: missing unique native target')
        groups = re.search(r'fileSystemSynchronizedGroups\s*=\s*\((.*?)\);', matching[0], re.S)
        if not groups or SHARED_GROUP not in groups[1]:
            raise ValueError(f'{target}: missing shared resource membership')
        if target == 'LabstreamTV' and TV_GROUP not in groups[1]:
            raise ValueError('LabstreamTV: missing platform resource membership')
        if target != 'LabstreamTV' and TV_GROUP in groups[1]:
            raise ValueError(f'{target}: unexpected tvOS platform resource membership')
    exception = objects.get(TV_EXCEPTION, '')
    allowed = re.fullmatch(
        rf'\s*isa\s*=\s*PBXFileSystemSynchronizedBuildFileExceptionSet;'
        rf'\s*membershipExceptions\s*=\s*\(\s*Resources/PrivacyInfo\.xcprivacy\s*,?\s*\);'
        rf'\s*target\s*=\s*{TV_TARGET}\s*;\s*', exception)
    if not allowed:
        raise ValueError('Expected exactly the approved tvOS shared-manifest exception')
    for identifier, path in ((SHARED_GROUP, 'Labstream/Shared'), (TV_GROUP, 'Labstream/Platforms/tvOS')):
        group = objects.get(identifier, '')
        if (not re.search(r'isa\s*=\s*PBXFileSystemSynchronizedRootGroup;', group)
                or not re.search(rf'path\s*=\s*{re.escape(path)};', group)):
            raise ValueError(f'Missing synchronized source group for {path}')
    shared_group = objects.get(SHARED_GROUP, '')
    exceptions = re.search(r'exceptions\s*=\s*\((.*?)\);', shared_group, re.S)
    if not exceptions or re.findall(r'[A-F0-9]{24}', exceptions[1]) != [TV_EXCEPTION]:
        raise ValueError('Shared group must attach only the approved tvOS exception')
    # Exactly one definition and one attachment, only on the shared synchronized root.
    if sum(block.count(TV_EXCEPTION) for block in objects.values()) != 1:
        raise ValueError('tvOS manifest exception attached outside the shared group')
    without_exception = project.replace(project_block(project, TV_EXCEPTION), '')
    if 'PrivacyInfo.xcprivacy' in without_exception:
        raise ValueError('Other explicit privacy manifest project configuration requires review')
    if not re.search(r'\bname\s*=\s*LabstreamTV;', objects.get(TV_TARGET, '')):
        raise ValueError('tvOS exception target does not name LabstreamTV')
    return {target: tv if target == 'LabstreamTV' else shared for target in TARGETS}


def project_block(project, object_id):
    # Used only to remove the already strictly validated exception definition.
    match = re.search(rf'^\t\t{object_id}[^\n]*=\s*\{{.*?\}};', project, re.M | re.S)
    if not match:
        raise ValueError('Missing exception definition')
    return match[0]


def check_products(products, source):
    if set(products) != set(TARGETS):
        raise ValueError('Supply exactly all four targets with --app TARGET=PATH')
    for target in TARGETS:
        app = products[target]
        info_path = app / ('Contents/Info.plist' if target == 'LabstreamMac' else 'Info.plist')
        with info_path.open('rb') as stream:
            info = plistlib.load(stream)
        platforms = {'Labstream': {'xros', 'xrsimulator'},
                     'LabstreamMobile': {'iphoneos', 'iphonesimulator'},
                     'LabstreamTV': {'appletvos', 'appletvsimulator'},
                     'LabstreamMac': {'macosx'}}
        if info.get('DTPlatformName') not in platforms[target]:
            raise ValueError(f'{target}: wrong or missing product platform')
        relative = Path('Contents/Resources/PrivacyInfo.xcprivacy') if target == 'LabstreamMac' else Path('PrivacyInfo.xcprivacy')
        if read_manifest(app / relative, target) != source[target]:
            raise ValueError(f'{target}: packaged manifest differs from source')
        manifests = sorted(app.rglob('PrivacyInfo.xcprivacy'))
        for path in manifests:
            with path.open('rb') as stream:
                plistlib.load(stream)
        print(f'{target}: app manifest matches; {len(manifests)} packaged privacy manifest(s)')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', action='append', default=[], metavar='TARGET=PATH')
    args = parser.parse_args()
    try:
        source = check_source()
        if args.app:
            pairs = [value.split('=', 1) for value in args.app]
            products = {target: Path(path) for target, path in pairs}
            if len(products) != len(pairs):
                raise ValueError('Duplicate target')
            check_products(products, source)
        print('Privacy manifest source contract passed (signed Release archive gate remains separate).')
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(1, f'privacy manifest: {error}\n')


if __name__ == '__main__':
    main()
