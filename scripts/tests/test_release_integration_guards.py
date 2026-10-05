"""Regression guards for the local-main / 1.7.2 integration boundary."""
import pathlib
import re
import unittest
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[2]


class ReleaseIntegrationGuards(unittest.TestCase):
    def test_p7_candidate_activation_stays_debug_macos_only(self):
        source = (ROOT / 'Labstream/Shared/Player/PlaybackController.swift').read_text()
        conditions = []
        activations = 0
        for line in source.splitlines():
            stripped = line.strip()
            if stripped.startswith('#if '):
                conditions.append(stripped[4:])
            elif stripped.startswith(('#else', '#elseif')) and conditions:
                conditions[-1] = 'alternate branch'
            elif stripped == '#endif':
                conditions.pop()
            if re.search(r'p7HDR10Fallback:\s*true', line):
                activations += 1
                self.assertIn('DEBUG && os(macOS)', conditions)
        self.assertEqual(activations, 1)
        self.assertIn('--vp-probe-p7-hdr10-candidate', source)
        self.assertIn('--vp-probe-allow-live', source)
        self.assertNotIn('useHDR10BaseLayer', source)

    def test_automatic_p7_rewriter_is_retired(self):
        self.assertFalse((ROOT / 'PMSKit/Sources/PMSKit/MediaSession/HDR10BaseLayerInitSegment.swift').exists())
        proxy = (ROOT / 'PMSKit/Sources/PMSKit/MediaSession/MediaSessionProxy.swift').read_text()
        self.assertNotIn('useHDR10BaseLayer', proxy)
        self.assertIn('p7HDR10Fallback: Bool = false', proxy)

    def test_mac_entitlements_have_unique_keys(self):
        for name in ['LabstreamMac.entitlements', 'LabstreamMacDevelopment.entitlements']:
            root = ET.parse(ROOT / 'Config' / name).getroot()
            keys = [element.text for element in root.findall('./dict/key')]
            self.assertEqual(len(keys), len(set(keys)), name)

    def test_download_health_collection_is_lazy(self):
        manager = (ROOT / 'Labstream/Capabilities/Downloads/Core/DownloadManager.swift').read_text()
        start = manager.index('    private func recordDownloadHealthSnapshotIfNeeded(')
        end = manager.index('    private func makeDownloadHealthSessionSnapshot(', start)
        method = manager[start:end]
        self.assertIn('DownloadHealthSnapshotPolicy.collectIfNeeded(', method)
        self.assertIn('enabled: AppDiagnostics.isEnabled', method)
        self.assertIn('diagnosticSnapshot(includePendingTempCleanupBytes: false)', method)
        self.assertIn('pendingTempBytes: { session.diagnosticSnapshot().pendingTempCleanupBytes }', method)
        session = (ROOT / 'Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift').read_text()
        self.assertIn('includePendingTempCleanupBytes ? pendingCFNetworkTempBytes() : 0', session)
        reattach = session[session.index('    private func recordPendingNetworkTemps('):]
        self.assertLess(reattach.index('guard AppDiagnostics.isEnabled'),
                        reattach.index('let candidates = cfNetworkTempDirectories()'))


    def test_counter_only_download_tests_do_not_scan_host_temp_files(self):
        for name in ['BackgroundDownloadStartupAdmissionTests.swift',
                     'DeferredDownloadStartupActivationTests.swift',
                     'DownloadCleanupOrderingTests.swift']:
            source = (ROOT / 'LabstreamTests' / name).read_text()
            self.assertNotIn('session.diagnosticSnapshot()', source, name)
            self.assertIn('diagnosticSnapshot(includePendingTempCleanupBytes: false)', source, name)
