#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "imageio-ffmpeg"]
# ///
"""Compare decoded audio and pre/post-effects capture; never claims speaker timing."""
import argparse
import functools
import http.server
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import threading
import uuid

spec = importlib.util.spec_from_file_location('lab', Path(__file__).with_name('playback-signal-lab.py'))
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)


def run(root, fixtures, modes, algorithms, decoded_audio=True):
    executable = lab.compile_host(root)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(lab.QuietHandler, directory=str(root)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    report = {'schema': 1, 'runID': str(uuid.uuid4()), 'status': 'running', 'results': []}
    report_path = root/'comparison-results.json'
    report_path.write_text(json.dumps(report, indent=2))
    try:
        for fixture in fixtures:
            playlist = (root/fixture/'index.m3u8').resolve()
            if not playlist.is_relative_to(root) or not playlist.is_file():
                raise ValueError('fixture must name an existing playlist directory under output')
            for algorithm in algorithms:
                for mode in modes:
                    rid = 'compare-'+str(uuid.uuid4())
                    directory = root/'runs'/rid
                    result = dict(fixture=fixture, mode=mode, algorithm=algorithm, runID=rid, decodedAudioEnabled=decoded_audio)
                    env = dict(os.environ, SIGNAL_LAB_AUDIO_TAP='0' if mode == 'off' else '1',
                               SIGNAL_LAB_TAP_PRE_EFFECTS='1' if mode == 'pre' else '0',
                               SIGNAL_LAB_PITCH_ALGORITHM=algorithm, SIGNAL_LAB_DISABLE_DECODED_AUDIO='0' if decoded_audio else '1')
                    try:
                        lab.command([executable, f'http://127.0.0.1:{server.server_port}/{fixture}/index.m3u8',
                                     directory, rid], env=env, capture_output=True, text=True, timeout=45)
                        data = json.loads((directory/'capture.json').read_text())
                        if data['runID'] != rid: raise ValueError('stale capture')
                        result.update(position=data['position'], audioBuffers=len(data['audio']), videoFrames=len(data['video']))
                        try:
                            result['signals'] = (lab.analyze_observation(directory, rid) if not data.get('managesPlayback', True)
                                                 else lab.analyze(directory, root/'reference.rgba', rid))
                            result['status'] = 'inconclusive' if result['signals'].get('evidenceStatus') == 'partial' else 'captured'
                        except (ValueError, OSError) as error:
                            result.update(status='inconclusive', reason=str(error))
                        if (directory/'tap.json').exists(): result['tap'] = lab.analyze_tap(directory)
                    except subprocess.CalledProcessError as error:
                        result.update(status='capture-failed', reason=error.stdout.strip()[-1000:])
                    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
                        result.update(status='inconclusive', reason=str(error)[:300])
                    report['results'].append(result)
                    report_path.write_text(json.dumps(report, indent=2))
                    print(json.dumps(result), flush=True)
        report['status'] = 'complete'
    finally:
        server.shutdown()
        server.server_close()
        report_path.write_text(json.dumps(report, indent=2))
        archive = root/'comparisons'
        archive.mkdir(exist_ok=True)
        (archive/(report['runID']+'.json')).write_text(json.dumps(report, indent=2))
    return report


def generate_controls(root):
    import imageio_ffmpeg
    controls = root/'controls'
    controls.mkdir(exist_ok=True)
    audio, video = lab.reference_signals()
    audio.tofile(controls/'source.f32le')
    video.tofile(controls/'source.rgb')
    cases = [('h264-no-bframes', 'libx264', 160, 90, ['-bf', '0']),
             ('hevc8-320', 'libx265', 320, 180, []),
             ('hevc8-640', 'libx265', 640, 360, []),
             ('hevc8-no-bframes', 'libx265', 160, 90, ['-bf', '0']),
             ('hevc8-level4', 'libx265', 160, 90, ['-level:v', '4.0']),
             ('hevc10-no-bframes', 'libx265', 160, 90, ['-bf', '0', '-pix_fmt', 'yuv420p10le']),
             ('hevc10-eac3-no-bframes', 'libx265', 160, 90, ['-bf', '0', '-pix_fmt', 'yuv420p10le']),
             ('hevc8-one-bframe', 'libx265', 160, 90, ['-bf', '1'])]
    manifest = []
    try:
        for name, codec, width, height, extra in cases:
            directory = controls/name
            directory.mkdir(exist_ok=True)
            args = ['-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', '160x90', '-r', '30',
                    '-i', controls/'source.rgb', '-f', 'f32le', '-ar', '48000', '-ac', '2',
                    '-i', controls/'source.f32le', '-vf', f'scale={width}:{height}:flags=neighbor',
                    '-c:v', codec, '-pix_fmt', 'yuv420p', '-crf', '16', '-g', '30', '-preset', 'fast']
            if codec == 'libx265': args += ['-tag:v', 'hvc1', '-x265-params', 'pools=1:frame-threads=1:log-level=error']
            args += [*extra, '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
                     '-c:a', 'eac3' if 'eac3' in name else 'aac', '-b:a', '192k', '-f', 'hls', '-hls_time', '1', '-hls_list_size', '0',
                     '-hls_segment_type', 'fmp4', directory/'index.m3u8']
            with (directory/'generation.log').open('w') as log:
                lab.command([imageio_ffmpeg.get_ffmpeg_exe(), '-hide_banner', '-loglevel', 'warning', '-y', *args],
                            stdout=log, stderr=subprocess.STDOUT)
            manifest.append(dict(fixture='controls/'+name, codec=codec, width=width, height=height, extra=extra))
    finally:
        (controls/'source.f32le').unlink(missing_ok=True)
        (controls/'source.rgb').unlink(missing_ok=True)
        (controls/'manifest.json').write_text(json.dumps(manifest, indent=2))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, default=lab.ROOT/'build/av-quality-matrix')
    p.add_argument('--fixture', action='append', default=None)
    p.add_argument('--mode', action='append', choices=('off', 'pre', 'post'))
    p.add_argument('--generate-controls', action='store_true')
    p.add_argument('--no-decoded-audio', action='store_true')
    p.add_argument('--algorithm', action='append', choices=('default', 'varispeed'))
    args = p.parse_args()
    root = args.output.resolve()
    if not root.is_relative_to(lab.ROOT/'build'): p.error('output must be under build/')
    if args.generate_controls:
        generate_controls(root)
        return
    run(root, args.fixture or ['clean'], args.mode or ['off', 'pre', 'post'], args.algorithm or ['default'], not args.no_decoded_audio)


if __name__ == '__main__': main()
