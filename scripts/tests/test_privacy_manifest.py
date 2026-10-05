import importlib.util
import plistlib
import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('privacy_manifest', ROOT / 'scripts/check-privacy-manifest.py')
privacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(privacy)


class PrivacyManifestTests(unittest.TestCase):
    def test_production_source_and_four_target_membership(self):
        privacy.check_source()

    def test_missing_target_resource_membership_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            manifest = root / privacy.MANIFEST
            manifest.parent.mkdir(parents=True)
            manifest.write_bytes((ROOT / privacy.MANIFEST).read_bytes())
            tv = root / privacy.TV_MANIFEST
            tv.parent.mkdir(parents=True)
            tv.write_bytes((ROOT / privacy.TV_MANIFEST).read_bytes())
            project = root / 'Labstream.xcodeproj/project.pbxproj'
            project.parent.mkdir()
            original = (ROOT / 'Labstream.xcodeproj/project.pbxproj').read_text()
            for target in privacy.TARGETS:
                with self.subTest(target=target):
                    # Removing a target must not accidentally pass on another target's group.
                    project.write_text(original.replace(f'name = {target};', f'name = Missing{target};'))
                    with self.assertRaises(ValueError):
                        privacy.check_source(root)

    def test_missing_wrong_or_duplicate_uptime_reason_fails(self):
        for entries in ([], [{'NSPrivacyAccessedAPIType': privacy.CATEGORY,
                             'NSPrivacyAccessedAPITypeReasons': ['3D61.1']}],
                        [{'NSPrivacyAccessedAPIType': privacy.CATEGORY,
                          'NSPrivacyAccessedAPITypeReasons': ['35F9.1']}] * 2):
            with self.subTest(entries=entries), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / 'PrivacyInfo.xcprivacy'
                path.write_bytes(plistlib.dumps({'NSPrivacyAccessedAPITypes': entries}))
                with self.assertRaises(ValueError):
                    privacy.read_manifest(path)

    def test_all_four_packaged_locations_required_and_match_source(self):
        source = privacy.check_source()
        with tempfile.TemporaryDirectory() as tmp:
            products = {}
            for target in privacy.TARGETS:
                app = Path(tmp) / target / 'Labstream.app'
                relative = 'Contents/Resources/PrivacyInfo.xcprivacy' if target == 'LabstreamMac' else 'PrivacyInfo.xcprivacy'
                path = app / relative
                path.parent.mkdir(parents=True)
                path.write_bytes(plistlib.dumps(source[target]))
                info = app / ('Contents/Info.plist' if target == 'LabstreamMac' else 'Info.plist')
                platform = dict(zip(privacy.TARGETS, ('xrsimulator', 'iphonesimulator', 'appletvsimulator', 'macosx')))[target]
                info.write_bytes(plistlib.dumps({'DTPlatformName': platform}))
                products[target] = app
            privacy.check_products(products, source)
            with self.assertRaises(ValueError):
                privacy.check_products({k: v for k, v in products.items() if k != 'LabstreamTV'}, source)
            with self.assertRaises(ValueError):
                privacy.check_products(dict(products, LabstreamTV=products['LabstreamMobile']), source)
            (products['LabstreamTV'] / 'PrivacyInfo.xcprivacy').unlink()
            with self.assertRaises(OSError):
                privacy.check_products(products, source)
            changed = dict(source['LabstreamTV'], NSPrivacyTracking=True)
            (products['LabstreamTV'] / 'PrivacyInfo.xcprivacy').write_bytes(plistlib.dumps(changed))
            with self.assertRaises(ValueError):
                privacy.check_products(products, source)

    def test_platform_specific_collected_data_and_purposes(self):
        source = privacy.check_source()
        shared = source['Labstream']
        tv = source['LabstreamTV']
        kinds = lambda data: {e['NSPrivacyCollectedDataType'] for e in data['NSPrivacyCollectedDataTypes']}
        self.assertEqual(len(kinds(shared)), 7)
        self.assertEqual(kinds(shared) - kinds(tv), {'NSPrivacyCollectedDataTypeCrashData'})
        mutations = []
        def altered(change):
            data = plistlib.loads(plistlib.dumps(shared))
            change(data)
            mutations.append(data)
        altered(lambda d: d.update(NSPrivacyTracking=True))
        altered(lambda d: d.update(NSPrivacyTrackingDomains=['tracking.example.test']))
        altered(lambda d: d['NSPrivacyCollectedDataTypes'].pop())
        altered(lambda d: d['NSPrivacyCollectedDataTypes'].append(d['NSPrivacyCollectedDataTypes'][0]))
        altered(lambda d: d['NSPrivacyCollectedDataTypes'][0].update(NSPrivacyCollectedDataTypeLinked=False))
        altered(lambda d: d['NSPrivacyCollectedDataTypes'][0].update(NSPrivacyCollectedDataTypeTracking=True))
        altered(lambda d: d['NSPrivacyCollectedDataTypes'][0].update(NSPrivacyCollectedDataTypePurposes=[privacy.FUNCTIONALITY]))
        for data in mutations:
            with self.subTest(data=data), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / 'PrivacyInfo.xcprivacy'
                path.write_bytes(plistlib.dumps(data))
                with self.assertRaises(ValueError):
                    privacy.read_manifest(path)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'PrivacyInfo.xcprivacy'
            path.write_bytes(plistlib.dumps(shared))
            with self.assertRaises(ValueError):
                privacy.read_manifest(path, 'LabstreamTV')
            path.write_bytes(plistlib.dumps(tv))
            with self.assertRaises(ValueError):
                privacy.read_manifest(path, 'LabstreamMac')

    def test_only_precise_tv_exception_is_allowed(self):
        original = (ROOT / 'Labstream.xcodeproj/project.pbxproj').read_text()
        exception = privacy.project_block(original, privacy.TV_EXCEPTION)
        mutations = [
            re.sub(r'target = ' + privacy.TV_TARGET, 'target = ' + privacy.SHARED_GROUP, original),
            original.replace('Resources/PrivacyInfo.xcprivacy', 'Other/PrivacyInfo.xcprivacy'),
            original.replace(exception, exception.replace('membershipExceptions = (', 'membershipExceptions = ( Other.swift,')),
            original.replace(exception, ''),
            original + '\n// PrivacyInfo.xcprivacy extra configuration\n',
            original.replace('path = Labstream/Shared;', 'exceptions = (' + privacy.TV_EXCEPTION + ',); path = Labstream/Shared;'),
            original.replace(privacy.TV_GROUP + ' /* Labstream/Platforms/tvOS */,', ''),
        ]
        for project_text in mutations:
            self.assertNotEqual(project_text, original)
            with self.subTest(project=project_text[-100:]), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                for relative in (privacy.MANIFEST, privacy.TV_MANIFEST):
                    path = root / relative
                    path.parent.mkdir(parents=True)
                    path.write_bytes((ROOT / relative).read_bytes())
                project = root / 'Labstream.xcodeproj/project.pbxproj'
                project.parent.mkdir()
                project.write_text(project_text)
                with self.assertRaises(ValueError):
                    privacy.check_source(root)


if __name__ == '__main__':
    unittest.main()
