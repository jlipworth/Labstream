#!/usr/bin/env python3
"""Check the uptime declaration and optionally all four built app manifests.

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


def read_manifest(path):
    with path.open('rb') as stream:
        data = plistlib.load(stream)
    entries = [entry for entry in data.get('NSPrivacyAccessedAPITypes', [])
               if entry.get('NSPrivacyAccessedAPIType') == CATEGORY]
    if len(entries) != 1 or entries[0].get('NSPrivacyAccessedAPITypeReasons') != ['35F9.1']:
        raise ValueError(f'{path.name}: expected one SystemBootTime declaration with 35F9.1')
    return data


def check_source(root=ROOT):
    data = read_manifest(root / MANIFEST)
    project = (root / 'Labstream.xcodeproj/project.pbxproj').read_text()
    blocks = re.findall(r'isa = PBXNativeTarget;(.*?)\n\t\t};', project, re.S)
    for target in TARGETS:
        matching = [block for block in blocks if f'name = {target};' in block]
        if len(matching) != 1 or '/* Labstream/Shared */' not in matching[0]:
            raise ValueError(f'{target}: missing shared resource membership')
    # Fail closed if an exclusion is introduced; review its effect rather than guessing.
    if 'PrivacyInfo.xcprivacy' in project:
        raise ValueError('Explicit privacy manifest project configuration requires review')
    return data


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
        if read_manifest(app / relative) != source:
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
