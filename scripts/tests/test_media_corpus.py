import importlib.util
from pathlib import Path
import unittest
from unittest import mock
import tempfile
import json
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location('media_corpus', Path(__file__).parents[1] / 'media-corpus.py')
corpus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus)


class MediaCorpusTests(unittest.TestCase):
    def test_stratification_interleaves_roots_and_retains_full_inventory(self):
        rows = [{'path': '/movies/b'}, {'path': '/tv/b'}, {'path': '/movies/a'}, {'path': '/tv/a'}, {'path': '/movies/c'}]
        ordered = corpus.stratified(rows, ['/movies', '/tv'])
        self.assertEqual([r['path'] for r in ordered[:2]], ['/movies/a', '/tv/a'])
        self.assertEqual(len(ordered), len(rows))
        self.assertEqual(ordered[-1]['path'], '/movies/c')

    def test_limit_bounds_probes_not_inventory(self):
        calls = []
        def run(command, **kwargs):
            if 'find' in command:
                return SimpleNamespace(stdout=b'/movies/a.mkv\x001\x001\x00/tv/b.mkv\x002\x002\x00', returncode=0)
            if 'timeout' in command:
                calls.append(command)
                return SimpleNamespace(stdout=b'{"streams":[{"codec_type":"video","codec_name":"hevc"}]}', returncode=0)
            return SimpleNamespace(stdout=b'', returncode=0)
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(corpus.subprocess, 'run', side_effect=run), mock.patch('sys.argv', ['media-corpus', '--context', 'test', '--root', '/movies', '--root', '/tv', '--output', temporary, '--limit', '1']), mock.patch('builtins.print'):
            corpus.main()
            inventory = json.loads((Path(temporary) / 'inventory.json').read_text())
            self.assertEqual(len(inventory['items']), 2)
            self.assertEqual(len(calls), 1)
            self.assertFalse(inventory['complete_probe_coverage'])
            self.assertEqual(inventory['items'][1]['error'], 'not_yet_probed')

    def test_unknown_fields_remain_explicit(self):
        facts = corpus.normalize({'streams': [{'codec_type': 'video', 'codec_name': 'hevc'}]})
        self.assertEqual(facts['container'], 'unknown')
        self.assertEqual(facts['streams'][0]['pix_fmt'], 'unknown')

    def test_video_audio_and_container_change_combination(self):
        base = {'format': {'format_name': 'matroska'}, 'streams': [{'codec_type': 'video', 'codec_name': 'hevc'}, {'codec_type': 'audio', 'codec_name': 'aac'}]}
        first = corpus.digest(corpus.combination(corpus.normalize(base)))
        base['streams'][1]['codec_name'] = 'ac3'
        self.assertNotEqual(first, corpus.digest(corpus.combination(corpus.normalize(base))))

    def test_smallest_representative_and_errors_excluded(self):
        facts = corpus.normalize({})
        rows = [{'id': 'a', 'size': 100, 'facts': facts}, {'id': 'b', 'size': 20, 'facts': facts}, {'id': 'c', 'error': 'timeout'}]
        groups = corpus.summarize(rows)
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0]['count'], 2)
        self.assertEqual(groups[0]['representative']['id'], 'b')

    def test_dv_profile_preserved_but_mastering_values_not_grouped(self):
        facts = corpus.normalize({'streams': [{'side_data_list': [{'side_data_type': 'DOVI configuration record', 'dv_profile': 5, 'unused': 42}]}]})
        side = corpus.combination(facts)['streams'][0]['side_data'][0]
        self.assertEqual(side['dv_profile'], 5)
        self.assertNotIn('unused', side)
        self.assertEqual(facts['streams'][0]['side_data'][0]['unused'], 42)


if __name__ == '__main__':
    unittest.main()
