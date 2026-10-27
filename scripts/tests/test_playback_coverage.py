"""Coverage is per file, and synthetic passes cannot become library-source passes."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('coverage', Path(__file__).parents[1]/'playback-coverage.py')
coverage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coverage)


def video(codec='h264', **fields):
    return dict(codec_type='video', codec_name=codec, profile='High', pix_fmt='yuv420p',
                width=1920, height=1080, disposition={}, **fields)


def audio(codec='aac', channels=2):
    return dict(codec_type='audio', codec_name=codec, channels=channels, channel_layout='stereo',
                sample_rate='48000', disposition={})


def row(identity, streams=None, **fields):
    return dict(id=identity, path='/private/title/'+identity, raw={'tags': {'title': 'private-title'}},
                facts=dict(container='mov,mp4,m4a,3gp,3g2,mj2', streams=streams or [video(), audio()]), **fields)


def inventory(rows):
    return dict(schema_version=1, discovered_video_files=len(rows), complete_file_inventory=True,
                complete_probe_coverage=not any(r.get('error') for r in rows), items=rows)


def passed_matrix():
    return dict(schema=1, status='complete', runID='matrix-run', results=[dict(name='h264-aac-fmp4',
        status='signal-pass', runID='capture-run', failures=[],
        fixture=dict(name='h264-aac-fmp4', status='generated'))])


class PlaybackCoverageTests(unittest.TestCase):
    def test_duplicate_audio_tracks_count_once_per_file(self):
        report = coverage.build_report(inventory([row('one', [video(), audio(), audio(), audio('ac3', 6)]), row('two')]))
        self.assertEqual(report['counts']['audioCodecFiles'], {'aac': 2, 'ac3': 1})
        self.assertEqual(report['counts']['audioCodecTracks'], {'aac': 3, 'ac3': 1})
        self.assertEqual(report['syntheticFamilyCoverage']['withFamilyFixture']['files'], 2)
        self.assertEqual(report['syntheticFamilyCoverage']['withFamilyFixture']['percent'], 100)

    def test_probe_error_and_cover_art_do_not_inflate_eligible_denominator(self):
        cover = video(); cover['disposition'] = {'attached_pic': 1}
        report = coverage.build_report(inventory([row('one'), row('cover-only', [cover, audio()]), row('bad', error='private-error')]))
        self.assertEqual(report['inventory']['eligibleVideoFiles'], 1)
        self.assertEqual(report['inventory']['successfulWithoutPlayableVideo'], 1)
        self.assertEqual(report['inventory']['probeErrors'], 1)
        self.assertEqual(report['counts']['videoCodecFiles'], {'h264': 1})
        self.assertEqual(report['counts']['audioCodecFiles'], {'aac': 2})

    def test_family_pass_does_not_validate_library_file_or_exact_combination(self):
        report = coverage.build_report(inventory([row('one')]), [passed_matrix()])
        self.assertEqual(report['syntheticFamilyCoverage']['withSuppliedFamilyPass']['files'], 1)
        self.assertEqual(report['exactLibraryValidation']['passedFiles'], 0)
        self.assertEqual(report['exactLibraryValidation']['status'], 'not-measured')
        self.assertEqual(report['priorityCombinations'][0]['exactSyntheticMatch'], 'not-established')
        self.assertEqual(report['priorityCombinations'][0]['libraryPlayback'], 'not-tested')

    def test_layout_channels_and_profile_differences_preserved(self):
        first = row('one')
        second = row('two', [video(), audio(channels=6)])
        third = row('three'); third['facts']['streams'][0]['width'] = 3840
        fourth = row('four'); fourth['facts']['streams'][0]['profile'] = 'Main'
        report = coverage.build_report(inventory([first, second, third, fourth]))
        self.assertEqual(report['inventory']['technicalCombinations'], 4)
        self.assertEqual(report['syntheticFamilyCoverage']['withFamilyAndChannelCountFixture']['files'], 4)

    def test_selection_is_deterministic_and_bounded(self):
        rows = [row('one'), row('two'), row('three', [video('vc1'), audio('dts', 6)])]
        forward = coverage.build_report(inventory(rows), limit=1)
        reverse = coverage.build_report(inventory(list(reversed(rows))), limit=1)
        self.assertEqual(forward, reverse)
        self.assertEqual(len(forward['priorityCombinations']), 1)
        self.assertEqual(forward['priorityPlan']['representedFiles'], 2)

    def test_private_tags_ids_paths_and_errors_are_not_exported(self):
        data = inventory([row('private-identity'), row('private-failure', error='private-error')])
        data['source'] = dict(host='private-host')
        data['items'][0]['facts']['streams'][0]['profile'] = '/private/unexpected'
        rendered = json.dumps(coverage.build_report(data))
        for secret in ('private-identity', 'private-failure', 'private-error', 'private-host', 'private-title', '/private/'):
            self.assertNotIn(secret, rendered)

    def test_unrecognized_alphanumeric_titles_and_hosts_are_not_technical_metadata(self):
        for private in ('Private Movie Title', 'PrivateMovieTitle', 'private-server.internal'):
            data = inventory([row('identity')])
            data['generated_at'] = private
            facts = data['items'][0]['facts']
            facts['container'] = private
            for stream in facts['streams']:
                for field in (*coverage.VIDEO_FIELDS, *coverage.AUDIO_FIELDS): stream[field] = private
            facts['streams'][0]['side_data'] = [{field: private for field in coverage.SIDE_FIELDS}]
            report = coverage.build_report(data)
            self.assertNotIn(private, json.dumps(report))
            self.assertNotIn(private, coverage.markdown(report))
            self.assertEqual(report['priorityCombinations'][0]['dimensions']['container'], 'unknown')

    def test_known_ffprobe_enums_and_bounded_numeric_types_survive(self):
        values = {'container': 'matroska,webm', 'codec_name': 'hevc', 'profile': 'Main 10',
                  'pix_fmt': 'yuv420p10le', 'width': 3840, 'height': 2160,
                  'bits_per_raw_sample': '10', 'sample_rate': '48000', 'channels': 6,
                  'channel_layout': '2 channels (FC+LFE)', 'r_frame_rate': '24000/1001',
                  'avg_frame_rate': '2075533189/86567030',
                  'color_transfer': 'smpte2084', 'color_primaries': 'bt2020', 'color_space': 'bt2020nc',
                  'side_data_type': 'DOVI configuration record', 'dv_profile': 8,
                  'generated_at': '2026-10-25T12:00:00+00:00'}
        for field, value in values.items():
            with self.subTest(field=field): self.assertEqual(coverage.safe_value(field, value), value)
        for field, value in [('width', -1), ('channels', 999), ('dv_profile', True),
                              ('generated_at', '2026-99-99T12:00:00+00:00'),
                              ('channel_layout', '2 channels (PRIVATE+HOST)')]:
            with self.subTest(field=field): self.assertEqual(coverage.safe_value(field, value), 'unknown')

    def test_unknown_codec_is_a_gap_not_a_failure(self):
        report = coverage.build_report(inventory([row('one', [video('vc1'), audio('unknown')])]))
        self.assertEqual(report['syntheticFamilyCoverage']['withFamilyFixture']['files'], 0)
        self.assertEqual(report['status'], 'reported')
        self.assertEqual(report['priorityCombinations'][0]['libraryPlayback'], 'not-tested')

    def test_invalid_inventory_fails_closed(self):
        valid = inventory([row('one')])
        variants = [None, {}, {**valid, 'schema_version': 2}, {**valid, 'discovered_video_files': 0},
                    {**valid, 'items': [row('one'), row('one')]},
                    {**valid, 'items': [dict(id='one', facts={})]}]
        for data in variants:
            with self.subTest(data=data):
                with self.assertRaises(coverage.InvalidCoverage): coverage.build_report(data)

    def test_incomplete_unknown_or_contradictory_result_fails_closed(self):
        variants = []
        data = passed_matrix(); data['status'] = 'running'; variants.append(data)
        data = passed_matrix(); data['results'][0]['failures'] = ['audio-gap']; variants.append(data)
        data = passed_matrix(); data['results'][0]['fixture']['name'] = 'different'; variants.append(data)
        data = passed_matrix(); data['results'][0]['name'] = 'not-a-profile'; variants.append(data)
        data = passed_matrix(); data['results'][0]['status'] = 'pass'; variants.append(data)
        data = passed_matrix(); data['results'] *= 2; variants.append(data)
        for data in variants:
            with self.subTest(data=data):
                with self.assertRaises(coverage.InvalidCoverage): coverage.build_report(inventory([row('one')]), [data])

    def test_mixed_historical_results_are_preserved_not_best_selected(self):
        failed = copy.deepcopy(passed_matrix())
        failed['results'][0].update(status='signal-mismatch', failures=['audio-gap'])
        report = coverage.build_report(inventory([row('one')]), [passed_matrix(), failed])
        profile = next(p for p in report['fixtureCatalog'] if p['id'] == 'matrix:h264-aac-fmp4')
        self.assertEqual(profile['suppliedOutcomes'], ['signal-mismatch', 'signal-pass'])

    def test_multichannel_downmix_pass_is_distinct_from_native_layout(self):
        rows = [dict(profile='aac-back', status='routing-pass', runID='run', requestedChannels=2,
                     failures=[], offlineReference={'failures': []}),
                dict(profile='aac-back', status='layout-unverified', runID='other', requestedChannels=6)]
        report = coverage.build_report(inventory([row('one')]), [rows])
        profile = next(p for p in report['fixtureCatalog'] if p['id'] == 'multichannel:aac-back')
        self.assertEqual(profile['suppliedOutcomes'], ['layout-unverified:output-6ch', 'routing-pass:output-2ch'])

    def test_six_channel_pass_requires_observed_layout_metadata(self):
        row = dict(profile='aac-back', status='routing-pass', runID='run', requestedChannels=6,
                   failures=[], offlineReference={'failures': []})
        for tags in (None, [], ['stereo'], [0], [True]):
            with self.subTest(tags=tags):
                with self.assertRaises(coverage.InvalidCoverage):
                    coverage.result_outcomes([[dict(row, observedChannelLayoutTags=tags)]], coverage.catalog())
        accepted = coverage.result_outcomes([[dict(row, observedChannelLayoutTags=[(121 << 16) | 6])]], coverage.catalog())
        self.assertIn('routing-pass:output-6ch', accepted['multichannel:aac-back'])


if __name__ == '__main__': unittest.main()
