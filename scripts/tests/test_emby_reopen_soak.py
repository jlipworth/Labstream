from pathlib import Path
import unittest

from _script_loader import load_script

soak = load_script('emby_reopen_soak', Path(__file__).parents[1] / 'emby-reopen-soak.py')


class EmbyReopenSoakTests(unittest.TestCase):
    def test_redacts_credentials_and_session_identifiers(self):
        line = 'GET /videos/1/hls1/main/0.m4s?api_key=SECRET&PlaySessionId=abc&DeviceId=dev&x=1'
        out = soak.redact(line)
        for secret in ('SECRET', 'abc', 'dev'):
            self.assertNotIn(secret, out)
        self.assertIn('x=1', out)

    def test_counts_app_and_server_signals(self):
        app = ['seek: remote stream re-open targetMs=1', 'remote.copy_child_verified backend=emby',
               'Resyncing AQ timeline',
               'probe.pass scenario_completed=true']
        server = ['Info DynamicHlsService: Starting transcoding because currentTranscodingIndex=null',
                  'Info DynamicHlsService: Starting transcoding because requestedIndex=40 and currentTranscodingIndex=2']
        app_counts = soak.count_signals(app, soak.APP_SIGNALS)
        server_counts = soak.count_signals(server, soak.SERVER_SIGNALS)
        self.assertEqual(app_counts['copy_child_verified'], 1)
        self.assertEqual(server_counts, dict(transcode_starts=2, starts_index_null=1, gap_restarts=1))
        self.assertEqual(soak.probe_result(app), ('pass', 'scenario_completed=true'))

    def test_diagnostics_are_scoped_to_the_run_processes(self):
        records = [
            dict(name='playback.remote_prewarm_phase', fields=dict(process_id=7, phase='master', playlist_kind='media')),
            dict(name='playback.remote_prewarm', fields=dict(process_id=7, outcome='playlistUnavailable')),
            dict(name='playback.emby_copy_target_warm', fields=dict(process_id=8, outcome='ready')),
            dict(name='playback.emby_copy_target_warm', fields=dict(process_id=8, outcome='timedOut')),
            dict(name='playback.remote_prewarm', fields=dict(process_id=99)),
        ]
        self.assertEqual(soak.count_diagnostics(records, {7}), dict(
            prewarm_ran=1, prewarm_fetched_media_as_master=1, target_warm_ready=0,
            target_warm_other=0, diag_copy_reopen_retry=0, proxy_opened=0))
        other = soak.count_diagnostics(records, {8})
        self.assertEqual((other['target_warm_ready'], other['target_warm_other']), (1, 1))

    def test_prewarm_on_a_copy_child_fails_the_run(self):
        app = soak.count_signals(['remote.copy_child_verified backend=emby'], soak.APP_SIGNALS)
        server = soak.count_signals([], soak.SERVER_SIGNALS)
        diag = dict(prewarm_ran=1, prewarm_fetched_media_as_master=1)
        findings = soak.classify_run(app, server, 'pass', diag)
        self.assertIn('prewarm_on_copy_child', findings)
        self.assertTrue(soak.run_failed(dict(verdict='pass', findings=findings)))

    def test_a_server_restart_storm_fails_the_run(self):
        server = dict(transcode_starts=20, starts_index_null=2, gap_restarts=soak.RESTART_STORM_THRESHOLD + 1)
        app = soak.count_signals([], soak.APP_SIGNALS)
        findings = soak.classify_run(app, server, 'pass')
        self.assertEqual(findings, ['server_restart_storm'])
        self.assertTrue(soak.run_failed(dict(verdict='pass', findings=findings)))
        calm = dict(transcode_starts=4, starts_index_null=2, gap_restarts=2)
        self.assertEqual(soak.classify_run(app, calm, 'pass'), [])

    def test_a_recovered_retry_is_reported_but_not_failed(self):
        app = soak.count_signals(['remote.emby_copy_reopen_retry'], soak.APP_SIGNALS)
        findings = soak.classify_run(app, soak.count_signals([], soak.SERVER_SIGNALS), 'pass')
        self.assertEqual(findings, ['copy_reopen_retry'])
        self.assertFalse(soak.run_failed(dict(verdict='pass', findings=findings)))
        self.assertTrue(soak.run_failed(dict(verdict='pending', findings=['probe_pending'])))


if __name__ == '__main__':
    unittest.main()
