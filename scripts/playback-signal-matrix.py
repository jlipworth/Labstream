#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "imageio-ffmpeg"]
# ///
"""Bounded codec/packaging experiments using the headless AVPlayer signal host."""
import argparse
from collections import Counter
import functools
import hashlib
import http.server
import importlib.util
import json
from pathlib import Path
import platform
import re
import subprocess
import threading
import uuid

spec = importlib.util.spec_from_file_location('signal_lab', Path(__file__).with_name('playback-signal-lab.py'))
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)

# SDR and stereo only. Presence here expresses a test request, not platform support.
PROFILES = [
    ('h264-aac-fmp4', 'libx264', 'aac', 'fmp4', 'yuv420p'),
    ('h264-aac-ts', 'libx264', 'aac', 'mpegts', 'yuv420p'),
    ('hevc8-aac-fmp4', 'libx265', 'aac', 'fmp4', 'yuv420p'),
    ('hevc10-aac-fmp4', 'libx265', 'aac', 'fmp4', 'yuv420p10le'),
    ('av1-10-aac-fmp4', 'libaom-av1', 'aac', 'fmp4', 'yuv420p10le'),
    ('mpeg2-ac3-ts', 'mpeg2video', 'ac3', 'mpegts', 'yuv420p'),
    ('mjpeg-aac-fmp4', 'mjpeg', 'aac', 'fmp4', 'yuvj420p'),
    ('h264-ac3-fmp4', 'libx264', 'ac3', 'fmp4', 'yuv420p'),
    ('h264-eac3-fmp4', 'libx264', 'eac3', 'fmp4', 'yuv420p'),
    ('h264-mp3-ts', 'libx264', 'libmp3lame', 'mpegts', 'yuv420p'),
    ('h264-alac-fmp4', 'libx264', 'alac', 'fmp4', 'yuv420p'),
    ('h264-flac-fmp4', 'libx264', 'flac', 'fmp4', 'yuv420p'),
    ('h264-opus-fmp4', 'libx264', 'libopus', 'fmp4', 'yuv420p'),
    ('hevc10-eac3-fmp4', 'libx265', 'eac3', 'fmp4', 'yuv420p10le'),
]
GAPS = [
    {'codec': 'VC-1', 'status': 'fixture-unavailable', 'reason': 'No VC-1 encoder in the bundled FFmpeg; needs a validated reference asset.'},
    {'codec': 'DTS', 'status': 'not-covered', 'reason': 'Observed in historical playback audit; no validated DTS fixture in this matrix.'},
    {'codec': 'multichannel/HDR/Dolby Vision', 'status': 'not-covered', 'reason': 'This matrix measures SDR and stereo only.'},
]


class FixtureError(ValueError):
    pass


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_files(root, files):
    if not files:
        raise FixtureError('missing fixture fingerprints')
    for name, expected in files.items():
        path = (root/name).resolve()
        if not path.is_relative_to(root.resolve()) or not path.is_file() or digest(path) != expected:
            raise FixtureError('fixture missing, modified, or outside output directory')


def parsed_streams(stderr):
    return [line.strip() for line in stderr.splitlines()
            if re.search(r'Stream #.*(?:Video:|Audio:)', line)]


def generate(root):
    import imageio_ffmpeg
    lab.generate(root)
    media = root/'matrix'
    media.mkdir(exist_ok=True)
    audio, video = lab.reference_signals()
    audio.tofile(media/'source.f32le')
    video.tofile(media/'source.rgb')
    records = []
    try:
        for name, encoder, audio_encoder, container, pixel in PROFILES:
            directory = media/name
            directory.mkdir(exist_ok=True)
            record = dict(name=name, videoEncoder=encoder, audioEncoder=audio_encoder,
                          segmentContainer=container, pixelFormat=pixel, channels=2,
                          sampleRate=48000, color='SDR BT.709', durationSeconds=12)
            args = ['-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', '160x90', '-r', '30',
                    '-i', media/'source.rgb', '-f', 'f32le', '-ar', '48000', '-ac', '2',
                    '-i', media/'source.f32le', '-c:v', encoder, '-pix_fmt', pixel, '-g', '30']
            if encoder in ('libx264', 'libx265'):
                args += ['-crf', '16', '-preset', 'fast']
            if encoder == 'libx265': args += ['-tag:v', 'hvc1', '-x265-params', 'pools=1:frame-threads=1:log-level=error']
            if encoder == 'libaom-av1': args += ['-cpu-used', '8', '-crf', '20', '-b:v', '0', '-threads', '2']
            if encoder in ('mjpeg', 'mpeg2video'): args += ['-q:v', '2']
            args += ['-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709', '-c:a', audio_encoder]
            if audio_encoder not in ('alac', 'flac'): args += ['-b:a', '192k']
            args += ['-strict', '-2', '-f', 'hls', '-hls_time', '1', '-hls_list_size', '0',
                     '-hls_segment_type', container, directory/'index.m3u8']
            try:
                with (directory/'generation.log').open('w') as log:
                    lab.command([imageio_ffmpeg.get_ffmpeg_exe(), '-hide_banner', '-loglevel', 'warning', '-y', *args],
                                stdout=log, stderr=subprocess.STDOUT)
                info = lab.command([imageio_ffmpeg.get_ffmpeg_exe(), '-hide_banner', '-i', directory/'index.m3u8',
                                    '-map', '0:v:0', '-map', '0:a:0', '-c', 'copy', '-f', 'null', '-'],
                                   capture_output=True, text=True)
                record.update(status='generated', streamDescriptions=parsed_streams(info.stderr),
                              playlist=str((directory/'index.m3u8').relative_to(root)),
                              files={str(p.relative_to(root)): digest(p) for p in directory.iterdir() if p.suffix in ('.m3u8', '.mp4', '.m4s', '.ts')})
            except subprocess.SubprocessError:
                record.update(status='generation-failed', reason='Encoder/muxer failed; see per-fixture generation.log. Not a player verdict.')
            records.append(record)
            print(name, record['status'], flush=True)
    finally:
        (media/'source.f32le').unlink(missing_ok=True)
        (media/'source.rgb').unlink(missing_ok=True)
        (root/'matrix-manifest.json').write_text(json.dumps({'schema': 1, 'ffmpeg': imageio_ffmpeg.get_ffmpeg_version(),
            'profiles': records, 'coverageGaps': GAPS, 'referenceSHA256': digest(root/'reference.rgba')}, indent=2))


def classify_error(error, output=''):
    if isinstance(error, FixtureError): return 'fixture-invalid'
    if isinstance(error, subprocess.TimeoutExpired): return 'capture-timeout'
    if 'capture failed: playerFailed' in output: return 'playback-not-ready'
    return 'capture-inconclusive'


def error_reason(error, output=''):
    if 'capture failed: playerFailed' in output:
        return 'Player did not reach readiness or preroll failed; codec support is unproven.'
    if isinstance(error, subprocess.TimeoutExpired):
        return f'Capture exceeded {error.timeout} seconds.'
    if isinstance(error, subprocess.CalledProcessError):
        return f'Capture process exited {error.returncode}; inspect hostOutput.'
    return str(error).splitlines()[0][:220]


def write_report(root, report):
    report['counts'] = dict(Counter(row['status'] for row in report['results']))
    (root/'matrix-results.json').write_text(json.dumps(report, indent=2))
    lines = ['# Headless codec matrix', '', f"Run status: {report['status']}", '', 'Scope: macOS AVPlayer, generated SDR stereo HLS, ten-second captures. No backend conversion or hardware acceptance.', '',
             '| Requested combination | Status | Signal findings |', '| --- | --- | --- |']
    for row in report['results']:
        lines.append(f"| {row['name']} | {row['status']} | {', '.join(row.get('failures', [])) or row.get('reason', '')} |")
    lines += ['', 'Absolute A/V synchronization remains unverified; offsets are relative to the fixed H.264/AAC clean baseline.', '',
              'Coverage gaps: VC-1 reference asset, DTS, multichannel routing, HDR/Dolby Vision, other platforms, and backend playback paths.']
    (root/'matrix-report.md').write_text('\n'.join(lines)+'\n')


def validate_profiles(profiles, selected=None):
    if not isinstance(profiles, list) or not profiles:
        raise FixtureError('matrix contains no requested profiles')
    names = [row.get('name') for row in profiles]
    if any(not isinstance(name, str) or not name for name in names) or len(names) != len(set(names)):
        raise FixtureError('invalid or duplicate profile names')
    if selected and not set(selected) <= set(names):
        raise FixtureError('requested profiles missing from manifest')


def run(root, selected=None):
    report = {'schema': 1, 'runID': str(uuid.uuid4()), 'status': 'validating',
              'platform': platform.platform(), 'coverageGaps': GAPS, 'results': []}
    write_report(root, report)
    try:
        manifest = json.loads((root/'matrix-manifest.json').read_text())
        if manifest.get('schema') != 1 or digest(root/'reference.rgba') != manifest['referenceSHA256']:
            raise FixtureError('invalid manifest/reference')
        validate_profiles(manifest.get('profiles'), selected)
        # Gate every sweep on all injected defects, not just the happy path.
        lab.run_host(root, lab.CASES)
        baseline = json.loads((root/'host-results.json').read_text())[0]
        report.update(status='running', baseline=baseline,
                      hostSourceSHA256=digest(lab.ROOT/'Labstream/Shared/Debug/DebugPlaybackSignalCapture.swift'),
                      analysisSourceSHA256=digest(Path(lab.__file__)),
                      manifestSHA256=digest(root/'matrix-manifest.json'))
    except Exception as error:
        report.update(status='preflight-failed', reason=str(error))
        write_report(root, report)
        raise
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(lab.QuietHandler, directory=str(root)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for fixture in manifest['profiles']:
            if selected and fixture['name'] not in selected: continue
            result = {'name': fixture['name'], 'fixture': fixture}
            if fixture['status'] != 'generated':
                result.update(status='generation-failed', reason=fixture['reason'])
            else:
                run_id = 'matrix-'+str(uuid.uuid4())
                directory = root/'runs'/run_id
                result['runID'] = run_id
                try:
                    verify_files(root, fixture['files'])
                    completed = lab.command([root/'signal-host', f"http://127.0.0.1:{server.server_port}/{fixture['playlist']}",
                                             directory, run_id], capture_output=True, text=True, timeout=45)
                    result.update(lab.analyze(directory, root/'reference.rgba', run_id, baseline['audioEnvelopeOffsetSeconds']))
                    result['status'] = 'signal-pass' if not result['failures'] else 'signal-mismatch'
                except (ValueError, OSError, subprocess.SubprocessError) as error:
                    output = str(getattr(error, 'stdout', '') or '')
                    result.update(status=classify_error(error, output), reason=error_reason(error, output))
                    if output: result['hostOutput'] = output[-1000:]
            report['results'].append(result)
            write_report(root, report)
            print(result['name'], result['status'], result.get('failures', []), flush=True)
        report['status'] = 'complete'
    finally:
        server.shutdown()
        server.server_close()
        write_report(root, report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('generate', 'run'))
    parser.add_argument('--output', type=Path, default=lab.ROOT/'build/av-quality-matrix')
    parser.add_argument('--profile', choices=[p[0] for p in PROFILES], action='append')
    args = parser.parse_args()
    root = args.output.resolve()
    if not root.is_relative_to(lab.ROOT/'build'): parser.error('output must be under build/')
    if args.action == 'generate': generate(root)
    else:
        report = run(root, args.profile)
        if any(r['status'] != 'signal-pass' for r in report['results']): raise SystemExit(1)


if __name__ == '__main__': main()
