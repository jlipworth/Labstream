#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy"]
# ///
"""Summarize an existing-player observation without judging unknown source content."""
import argparse
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import uuid

spec = importlib.util.spec_from_file_location('lab', Path(__file__).with_name('playback-signal-lab.py'))
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)


def self_test():
    import numpy as np
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        data = dict(schema=1, runID='test', managesPlayback=False, initialPosition=2, position=10,
                    requestedDurationSeconds=8, channels=2, sampleRate=48000, width=160, height=90,
                    audio=[dict(pts=2+i/10, frames=4800, offset=i*4800*8) for i in range(80)],
                    video=[dict(pts=2+i/30, offset=i*160*90*4) for i in range(240)])
        (directory/'capture.json').write_text(json.dumps(data))
        np.zeros((8*48000, 2), dtype='<f4').tofile(directory/'audio.f32le')
        np.zeros((240, 90, 160, 4), dtype='u1').tofile(directory/'video.rgba')
        result = lab.analyze_observation(directory, 'test')
        assert result['evidenceStatus'] == 'complete'
        assert result['qualityVerdict'] == 'not-evaluated-no-reference'  # Silence is legitimate unknown content.
        expected_errors = {'stale': 'stale or non-observer capture',
                           'truncated': 'truncated observer capture',
                           'nonmonotonic': 'nonmonotonic observer timestamps',
                           'invalid-duration': 'invalid observation window',
                           'unstable-sequence': 'unstable audio sequence',
                           'missing-generation': 'unstable audio sequence',
                           'pre-window': 'retained audio outside observation window',
                           'future-window': 'retained audio outside observation window'}
        for mutation, expected_error in expected_errors.items():
            changed = copy.deepcopy(data)
            # Each negative case starts with valid bytes and metadata so an earlier
            # corruption cannot mask the condition this case is supposed to reject.
            np.zeros((8*48000, 2), dtype='<f4').tofile(directory/'audio.f32le')
            if mutation == 'truncated': (directory/'audio.f32le').write_bytes(b'')
            if mutation == 'nonmonotonic':
                changed['audio'][1]['pts'] = changed['audio'][0]['pts']
            if mutation == 'invalid-duration': changed['requestedDurationSeconds'] = float('nan')
            if mutation in ('unstable-sequence', 'missing-generation'):
                changed.update(retainedAudioOutput=True, audioSequenceStable=False)
                if mutation == 'unstable-sequence': changed['audioSequenceGeneration'] = 1
                else: changed['audioSequenceStable'] = True
            if mutation in ('pre-window', 'future-window'):
                changed['retainedAudioOutput'] = True
                changed['audio'][0 if mutation == 'pre-window' else -1]['pts'] = 1.9 if mutation == 'pre-window' else 10
            (directory/'capture.json').write_text(json.dumps(changed))
            try: lab.analyze_observation(directory, 'old' if mutation == 'stale' else 'test')
            except ValueError as error: assert str(error) == expected_error, (mutation, str(error))
            else: raise AssertionError(mutation+' admitted')
    print('observer evidence self-test passed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', nargs='?', type=Path)
    parser.add_argument('--run-id', type=uuid.UUID)
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test: self_test(); return
    if args.directory is None or args.run_id is None: parser.error('directory and --run-id are required')
    result = lab.analyze_observation(args.directory, str(args.run_id).upper())
    print(json.dumps(result, indent=2))
    if result['evidenceStatus'] != 'complete': raise SystemExit(1)

if __name__ == '__main__': main()
