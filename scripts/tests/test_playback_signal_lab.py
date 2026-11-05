"""Evidence admission checks must fail closed before any quality comparison."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('signal_lab', Path(__file__).parents[1] / 'playback-signal-lab.py')
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)


class SignalEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.data = {'schema': 1, 'runID': 'current', 'sampleRate': 48000, 'channels': 2,
                     'width': 160, 'height': 90, 'position': 10,
                     'audio': [{'pts': i/10, 'host': i/10, 'player': i/10,
                                'frames': 4800, 'offset': i*4800*8} for i in range(100)],
                     'video': [{'pts': i/30, 'host': i/30, 'player': i/30,
                                'offset': i*160*90*4} for i in range(300)]}

    def test_sync_threshold_is_stable_at_float_boundary(self):
        self.assertFalse(lab.offset_mismatch(-0.01, -0.09))
        self.assertFalse(lab.offset_mismatch(0.08, 0))
        self.assertTrue(lab.offset_mismatch(0.085, 0))
        self.assertTrue(lab.offset_mismatch(-0.085, 0))
        self.assertFalse(lab.offset_mismatch(0.25, None))

    def test_audio_classifier_distinguishes_injected_defects(self):
        clean = dict(audioGain=1, silentFraction=0, audioEnvelopeOffsetSeconds=0.11,
                     maxTimestampGapSeconds=0)
        self.assertEqual(lab.audio_failures(clean, 0.11), [])
        for key, value, expected in [('audioGain', 0.25, 'audio-gain'),
                                      ('silentFraction', 0.12, 'audio-gap'),
                                      ('audioEnvelopeOffsetSeconds', 0.36, 'audio-sync'),
                                      ('maxTimestampGapSeconds', 0.02, 'audio-timestamps')]:
            with self.subTest(expected=expected):
                self.assertEqual(lab.audio_failures({**clean, key: value}, 0.11), [expected])

    def test_complete_current_capture_is_admitted(self):
        lab.validate_manifest(self.data, 'current')

    def test_stale_empty_nonfinite_and_truncated_are_rejected(self):
        for key, value in [('runID', 'old'), ('audio', []), ('video', []),
                           ('position', float('nan')), ('position', 4), ('channels', 1)]:
            with self.subTest(key=key, value=value):
                data = copy.deepcopy(self.data)
                data[key] = value
                with self.assertRaises(ValueError): lab.validate_manifest(data, 'current')

    def test_sampling_holes_and_bad_offsets_are_rejected(self):
        data = copy.deepcopy(self.data)
        del data['video'][30:60]
        with self.assertRaises(ValueError): lab.validate_manifest(data, 'current')
        data = copy.deepcopy(self.data)
        data['audio'][5]['offset'] = 0
        with self.assertRaises(ValueError): lab.validate_manifest(data, 'current')
        data = copy.deepcopy(self.data)
        data['video'][5]['pts'] = float('nan')
        with self.assertRaises(ValueError): lab.validate_manifest(data, 'current')


if __name__ == '__main__': unittest.main()
