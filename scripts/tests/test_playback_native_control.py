import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

spec = importlib.util.spec_from_file_location('native_control', Path(__file__).parents[1] / 'playback-native-control.py')
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)


class NativeControlTests(unittest.TestCase):
    def test_completion_without_required_windows_is_not_a_pass(self):
        rows = control.classify_events([], 'lifecycle')
        self.assertEqual(len(rows), 6)
        self.assertTrue(all(row['status'] == 'inconclusive' for row in rows))

    def test_tap_needs_distinct_seek_epochs_and_all_integrity_flags(self):
        rows = [dict(kind='tap', window=label, audioCoverage='captured', audioBuffers=100,
                     observedSeconds=8, audioMaxTimestampGapSeconds=0, epochStable=True,
                     streamEpoch=index, overflow=False, unsupportedFormat=False, invalidTime=False)
                for index, label in enumerate(('tap-initial', 'tap-forward', 'tap-backward'))]
        self.assertTrue(all(r['status'] == 'pass' for r in control.classify_events(rows, 'tap-mixed')))
        rows[1]['streamEpoch'] = 0
        self.assertEqual(control.classify_events(rows, 'tap-mixed')[1]['status'], 'inconclusive')
        rows[0]['overflow'] = True
        self.assertEqual(control.classify_events(rows, 'tap-mixed')[0]['status'], 'inconclusive')
        rows[0]['overflow'] = False
        rows[0]['audioMaxTimestampGapSeconds'] = float('nan')
        self.assertEqual(control.classify_events(rows, 'tap-mixed')[0]['status'], 'inconclusive')

    def test_duplicate_window_is_rejected(self):
        row = dict(kind='observation', window='control-initial', audioCoverage='captured',
                   audioBuffers=47, observedSeconds=8, audioMaxTimestampGapSeconds=0, audioSequenceStable=True)
        self.assertEqual(control.classify_events([row, row], 'retained')[0]['status'], 'inconclusive')

    def test_hls_dependencies_are_hashed_and_changes_detected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            playlist = root / 'index.m3u8'
            playlist.write_text('#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:1\npart.m4s\n')
            (root / 'init.mp4').write_bytes(b'init')
            (root / 'part.m4s').write_bytes(b'part')
            first = control.fixture_files(playlist)
            self.assertEqual(set(first), {'index.m3u8', 'init.mp4', 'part.m4s'})
            (root / 'part.m4s').write_bytes(b'changed')
            self.assertNotEqual(control.fixture_files(playlist), first)
            for ref in ('../outside.mp4', 'https://example.com/remote.mp4'):
                playlist.write_text('#EXTM3U\n' + ref)
                with self.assertRaises(ValueError): control.fixture_files(playlist)

    def test_range_server_serves_only_explicit_fixture_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'fixture.mp4').write_bytes(b'0123456789')
            (root / 'private.mp4').write_bytes(b'not served')
            server = control.http.server.ThreadingHTTPServer(('127.0.0.1', 0), control.RangeHandler)
            server.fixture_root = root
            server.allowed_files = {'fixture.mp4'}
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = f'http://127.0.0.1:{server.server_port}'
            try:
                request = urllib.request.Request(base + '/fixture.mp4', headers={'Range': 'bytes=2-5'})
                with urllib.request.urlopen(request, timeout=3) as response:
                    self.assertEqual(response.status, 206)
                    self.assertEqual(response.headers['Content-Range'], 'bytes 2-5/10')
                    self.assertEqual(response.read(), b'2345')
                with urllib.request.urlopen(urllib.request.Request(base + '/fixture.mp4', method='HEAD'), timeout=3) as response:
                    self.assertEqual(response.headers['Content-Length'], '10')
                    self.assertEqual(response.read(), b'')
                for path in ('/private.mp4', '/%2e%2e/outside.mp4'):
                    with self.assertRaises(urllib.error.HTTPError) as error:
                        urllib.request.urlopen(base + path, timeout=3)
                    self.assertEqual(error.exception.code, 404)
                with self.assertRaises(urllib.error.HTTPError) as error:
                    urllib.request.urlopen(urllib.request.Request(base + '/fixture.mp4', headers={'Range': 'bytes=20-30'}), timeout=3)
                self.assertEqual(error.exception.code, 416)
            finally:
                server.shutdown(); server.server_close(); thread.join(timeout=3)

    def test_production_and_outside_app_paths_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaises(ValueError): control.validate_app(root / 'Labstream.app', root)

    def test_stale_run_and_incomplete_fragments_rejected(self):
        raw = json.dumps({'eventMessage': 'evidence.observation payload={"runID":"old"}'})
        with self.assertRaises(ValueError): control.decode_events(raw, 'new')
        raw = json.dumps({'eventMessage': 'evidence.tap.part index=0 count=2 payload=e30='})
        with self.assertRaises(ValueError): control.decode_events(raw, 'new')

    def test_missing_build_attestation_does_not_claim_verified_build(self):
        self.assertFalse(control.verify_build(None, None, {}))

    def test_stream_and_show_timestamp_variants_do_not_duplicate_windows(self):
        message = 'evidence.observation payload={"runID":"current","window":"control-initial"}'
        stream = json.dumps(dict(timestamp='a', eventMessage=message))
        shown = json.dumps(dict(timestamp='b', eventMessage=message))
        events, _, _ = control.decode_events(stream, 'current', shown)
        self.assertEqual(len(events), 1)
        # A real second occurrence within one source still fails uniqueness admission.
        events, _, _ = control.decode_events(stream, 'current', shown + '\n' + json.dumps(dict(timestamp='c', eventMessage=message)))
        self.assertEqual(len(events), 2)


if __name__ == '__main__': unittest.main()
