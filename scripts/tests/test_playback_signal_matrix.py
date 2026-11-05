import importlib.util
import json
from unittest import mock
from types import SimpleNamespace
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('signal_matrix', Path(__file__).parents[1]/'playback-signal-matrix.py')
matrix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(matrix)


class MatrixEvidenceTests(unittest.TestCase):
    def test_empty_duplicate_and_missing_selections_cannot_pass(self):
        for profiles, selected in [([], None), ([{'name': 'a'}, {'name': 'a'}], None),
                                   ([{'name': 'a'}], ['missing'])]:
            with self.assertRaises(matrix.FixtureError): matrix.validate_profiles(profiles, selected)
        matrix.validate_profiles([{'name': 'a'}], ['a'])

    def test_mutated_missing_and_external_fixtures_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root/'index.m3u8'
            fixture.write_text('#EXTM3U\n')
            fingerprints = {'index.m3u8': matrix.digest(fixture)}
            matrix.verify_files(root, fingerprints)
            fixture.write_text('changed')
            with self.assertRaises(matrix.FixtureError): matrix.verify_files(root, fingerprints)
            fixture.unlink()
            with self.assertRaises(matrix.FixtureError): matrix.verify_files(root, fingerprints)
            with self.assertRaises(matrix.FixtureError): matrix.verify_files(root, {})
            with self.assertRaises(matrix.FixtureError): matrix.verify_files(root, {'../outside': '123'})

    def test_capture_failure_is_not_a_signal_failure_or_codec_verdict(self):
        self.assertEqual(matrix.classify_error(ValueError('no audio')), 'capture-inconclusive')
        self.assertEqual(matrix.classify_error(subprocess.TimeoutExpired('host', 45)), 'capture-timeout')
        self.assertEqual(matrix.classify_error(matrix.FixtureError('changed')), 'fixture-invalid')
        self.assertEqual(matrix.classify_error(subprocess.CalledProcessError(1, 'host'),
                                              'capture failed: playerFailed'), 'playback-not-ready')

    def test_format_evidence_keeps_streams_and_excludes_paths(self):
        text = "Input #0 from '/private/file':\n  Stream #0:0: Video: hevc (Main 10), yuv420p10le\n  Stream #0:1: Audio: eac3, 48000 Hz, stereo\nOutput #0: null"
        result = matrix.parsed_streams(text)
        self.assertEqual(len(result), 2)
        self.assertNotIn('/private', str(result))

    def test_all_requested_profiles_are_unique_and_missing_codecs_explicit(self):
        names = [p[0] for p in matrix.PROFILES]
        self.assertEqual(len(names), len(set(names)))
        self.assertTrue({'VC-1', 'DTS'} <= {r['codec'] for r in matrix.GAPS})

    def test_bad_fixture_does_not_discard_next_case(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root/'reference.rgba').write_bytes(b'reference')
            (root/'good.m3u8').write_text('#EXTM3U')
            profiles = [
                {'name': 'bad', 'status': 'generated', 'playlist': 'missing', 'files': {'missing': 'bad'}},
                {'name': 'good', 'status': 'generated', 'playlist': 'good.m3u8', 'files': {'good.m3u8': matrix.digest(root/'good.m3u8')}}]
            (root/'matrix-manifest.json').write_text(json.dumps({'schema': 1,
                'referenceSHA256': matrix.digest(root/'reference.rgba'), 'profiles': profiles}))
            (root/'host-results.json').write_text(json.dumps([{'audioEnvelopeOffsetSeconds': 0}]))
            with (mock.patch.object(matrix.lab, 'run_host'), mock.patch.object(matrix.lab, 'command', return_value=SimpleNamespace(stdout='')),
                  mock.patch.object(matrix.lab, 'analyze', return_value={'failures': []}), mock.patch('builtins.print')):
                result = matrix.run(root)
            self.assertEqual([r['status'] for r in result['results']], ['fixture-invalid', 'signal-pass'])
            self.assertEqual(result['status'], 'complete')

    def test_failed_preflight_replaces_old_green_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root/'matrix-results.json').write_text('{"status":"complete","results":[{"status":"signal-pass"}]}')
            with self.assertRaises(FileNotFoundError): matrix.run(root)
            result = json.loads((root/'matrix-results.json').read_text())
            self.assertEqual(result['status'], 'preflight-failed')
            self.assertEqual(result['results'], [])


if __name__ == '__main__': unittest.main()
