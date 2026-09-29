import importlib.util
import plistlib
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
                path.write_bytes(plistlib.dumps(source))
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
            changed = dict(source, NSPrivacyTracking=True)
            (products['LabstreamTV'] / 'PrivacyInfo.xcprivacy').write_bytes(plistlib.dumps(changed))
            with self.assertRaises(ValueError):
                privacy.check_products(products, source)


if __name__ == '__main__':
    unittest.main()
