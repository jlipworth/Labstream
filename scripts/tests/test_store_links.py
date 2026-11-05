"""The in-app support/privacy links must match the App Store Connect metadata URLs."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LINKS = ROOT / 'Labstream/Shared/UI/LabstreamLinks.swift'
METADATA = ROOT / 'appstore/metadata'


def swift_links():
    text = LINKS.read_text()
    base = re.search(r'static let siteBase = "([^"]+)"', text).group(1)
    return {
        'privacy': base + re.search(r'privacyPolicy = URL\(string: siteBase \+ "([^"]*)"\)', text).group(1),
        'support': base + re.search(r'support = URL\(string: siteBase \+ "([^"]*)"\)', text).group(1),
        'email': re.search(r'supportEmailAddress = "([^"]+)"', text).group(1),
    }


class StoreLinkTests(unittest.TestCase):
    def test_privacy_link_matches_app_store_privacy_url(self):
        url = (METADATA / 'app/en-US/privacy_policy_url.txt').read_text().strip()
        self.assertEqual(swift_links()['privacy'], url)

    def test_support_link_matches_every_platform_support_url(self):
        files = sorted(METADATA.glob('*/en-US/support_url.txt'))
        self.assertTrue(files)
        for path in files:
            with self.subTest(platform=path.parts[-3]):
                self.assertEqual(swift_links()['support'], path.read_text().strip())

    def test_support_email_is_published_on_the_support_page(self):
        self.assertIn(swift_links()['email'], (ROOT / 'SUPPORT.md').read_text())

    def test_site_source_pages_use_only_absolute_links(self):
        """labstream.app renders PRIVACY.md and SUPPORT.md outside the repo, so relative links break."""
        for name in ('PRIVACY.md', 'SUPPORT.md'):
            text = (ROOT / name).read_text()
            relative = [m for m in re.findall(r'\]\(([^)\s]+)\)', text)
                        if not re.match(r'(https?:|mailto:|#)', m)]
            with self.subTest(page=name):
                self.assertEqual(relative, [])


if __name__ == '__main__':
    unittest.main()
