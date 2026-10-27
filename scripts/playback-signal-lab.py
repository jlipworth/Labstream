#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "imageio-ffmpeg"]
# ///
"""Local synthetic HLS experiments. No server credentials or library media required."""
from __future__ import annotations

import argparse
import functools
import http.server
import json
import math
import os
import shutil
import subprocess
import threading
import time
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RATE, FPS, WIDTH, HEIGHT, DURATION = 48000, 30, 160, 90, 12
CASES = ("clean", "audio-gap", "audio-gain", "audio-delay", "video-freeze", "video-bright")
EXPECTED = {"clean": set(), "audio-gap": {"audio-gap"}, "audio-gain": {"audio-gain"},
            "audio-delay": {"audio-sync"}, "video-freeze": {"video-content"},
            "video-bright": {"video-content"}}


def command(args, **kwargs):
    kwargs.setdefault('timeout', 120)
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def ffmpeg(*args):
    import imageio_ffmpeg
    return command([imageio_ffmpeg.get_ffmpeg_exe(), "-hide_banner", "-loglevel", "error", "-y", *args])


def reference_signals():
    import numpy as np
    t = np.arange(RATE * DURATION) / RATE
    amplitude = np.where(t % 1 < 0.12, 0.5, 0.2)
    clean_audio = np.column_stack([amplitude * np.sin(2*np.pi*f*t) for f in (440, 880)]).astype('<f4')
    frames = []
    for n in range(FPS * DURATION):
        sec = n / FPS
        gray = 220 if sec % 1 < 0.12 else int(90 + 35*np.sin(2*np.pi*sec/3))
        frame = np.full((HEIGHT, WIDTH, 3), gray, dtype=np.uint8)
        for index, color in enumerate(((180, 40, 40), (40, 180, 40), (40, 40, 180), (128, 128, 128))):
            frame[60:, index*40:(index+1)*40] = color
        frames.append(frame)
    return clean_audio, np.array(frames)


def generate(root):
    import imageio_ffmpeg
    import numpy as np
    root.mkdir(parents=True, exist_ok=True)
    clean_audio, clean_video = reference_signals()
    for case in CASES:
        directory = root / case
        directory.mkdir(exist_ok=True)
        audio, video = clean_audio.copy(), clean_video.copy()
        if case == "audio-gap": audio[4*RATE:5*RATE] = 0
        if case == "audio-gain": audio *= 0.25
        if case == "audio-delay": audio = np.concatenate([np.zeros((RATE//4, 2), dtype='<f4'), audio])[:len(audio)]
        if case == "video-freeze": video[4*FPS:5*FPS] = video[4*FPS-1]
        if case == "video-bright": video = np.clip(video.astype(int) + 50, 0, 255).astype(np.uint8)
        audio.tofile(directory / "input.f32le")
        video.tofile(directory / "input.rgb")
        ffmpeg("-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "160x90", "-r", str(FPS),
               "-i", directory / "input.rgb", "-f", "f32le", "-ar", str(RATE), "-ac", "2",
               "-i", directory / "input.f32le", "-c:v", "libx264", "-pix_fmt", "yuv420p",
               "-crf", "16", "-g", "30", "-sc_threshold", "0", "-color_primaries", "bt709",
               "-color_trc", "bt709", "-colorspace", "bt709", "-c:a", "aac", "-b:a", "192k",
               "-f", "hls", "-hls_time", "1", "-hls_list_size", "0", "-hls_segment_type", "fmp4",
               directory / "index.m3u8")
        (directory / "input.f32le").unlink()
        (directory / "input.rgb").unlink()
    ffmpeg("-i", root / "clean/index.m3u8", "-an", "-f", "rawvideo", "-pix_fmt", "rgba", root / "reference.rgba")
    (root / "fixture.json").write_text(json.dumps({"schema": 1, "cases": CASES,
        "video": "H.264 SDR BT.709 160x90 30fps", "audio": "AAC stereo 48kHz",
        "duration": DURATION, "ffmpeg": imageio_ffmpeg.get_ffmpeg_version()}, indent=2))


def validate_manifest(data, run_id):
    if data.get('schema') != 1 or data.get('runID') != run_id:
        raise ValueError('unsupported or stale capture')
    if (data.get('sampleRate'), data.get('channels'), data.get('width'), data.get('height')) != (RATE, 2, WIDTH, HEIGHT):
        raise ValueError('unexpected capture format')
    ar, vr = data['audio'], data['video']
    if len(ar) < 10 or len(vr) < 200 or not math.isfinite(data['position']) or data['position'] < 9.5:
        raise ValueError('incomplete capture; never a quality pass')
    for rows in (ar, vr):
        if any(not math.isfinite(row[key]) for row in rows for key in ('pts', 'host', 'player', 'offset')):
            raise ValueError('nonfinite capture metadata')
        if rows[0]['pts'] > 0.25 or rows[-1]['pts'] < 9.5:
            raise ValueError('missing beginning or end of capture')
        if any(b['pts'] <= a['pts'] for a, b in zip(rows, rows[1:])):
            raise ValueError('nonmonotonic capture timestamps')
    if max(b['pts']-a['pts'] for a, b in zip(vr, vr[1:])) > 0.2:
        raise ValueError('video sampling gap; quality result inconclusive')
    offset = 0
    for row in ar:
        if row['offset'] != offset or row['frames'] <= 0 or row['frames'] != int(row['frames']):
            raise ValueError('invalid audio offsets or sample count')
        offset += int(row['frames'])*8
    if any(row['offset'] != index*WIDTH*HEIGHT*4 for index, row in enumerate(vr)):
        raise ValueError('invalid video offsets')


def offset_mismatch(measured, baseline, tolerance=0.08):
    # Grid search arithmetic can represent exactly 80 ms as 0.08000000000000007.
    return baseline is not None and abs(measured-baseline) > tolerance + 1e-9


def measure_audio(rows, audio):
    import numpy as np
    if not rows or not np.isfinite(audio).all():
        raise ValueError('missing or nonfinite audio')
    offset = 0
    for row in rows:
        n = row['frames']
        if n <= 0 or int(n) != n or row['offset'] != offset or not math.isfinite(row['pts']):
            raise ValueError('invalid audio sample metadata')
        offset += int(n)*8
    if offset != audio.size*4 or rows[0]['pts'] > 0.25 or rows[-1]['pts']+rows[-1]['frames']/RATE < 9.5:
        raise ValueError('incomplete audio coverage')
    times, levels = [], []
    gaps = []
    previous_end = None
    for row in rows:
        n, start = int(row['frames']), int(row['offset']) // 8
        samples = audio[start:start+n]
        for offset in range(0, n, 480):
            block = samples[offset:offset+480]
            times.append(row['pts'] + (offset + len(block)/2) / RATE)
            levels.append(float(np.sqrt(np.mean(block**2))))
        if previous_end is not None: gaps.append(row['pts'] - previous_end)
        previous_end = row['pts'] + n/RATE
    times, levels = np.array(times), np.array(levels)
    valid = (times > 1) & (times < 9)
    t, rms = times[valid], levels[valid]
    # Pulse-envelope alignment; carrier phase is intentionally irrelevant after lossy encoding.
    shifts = np.arange(-0.4, 0.401, 0.005)
    errors = []
    for shift in shifts:
        expected = np.where((t-shift) % 1 < 0.12, 0.5, 0.2) / np.sqrt(2)
        gain = float(np.dot(rms, expected) / np.dot(expected, expected))
        errors.append(float(np.mean((rms-gain*expected)**2)))
    shift = float(shifts[np.argmin(errors)])
    base = rms[((t-shift) % 1 > 0.2) & ((t-shift) % 1 < 0.9)]
    gain = float(np.median(base) / (0.2 / np.sqrt(2)))
    silent = float(np.mean(rms < 0.01))
    return {'audioGain': gain, 'audioEnvelopeOffsetSeconds': shift,
            'silentFraction': silent, 'maxTimestampGapSeconds': max((abs(x) for x in gaps), default=0),
            'peak': float(np.max(np.abs(audio)))}


def audio_failures(measured, baseline_offset=None):
    failures = []
    if measured['silentFraction'] > 0.03: failures.append('audio-gap')
    if not 0.8 < measured['audioGain'] < 1.2: failures.append('audio-gain')
    if offset_mismatch(measured['audioEnvelopeOffsetSeconds'], baseline_offset):
        failures.append('audio-sync')
    if measured['maxTimestampGapSeconds'] > 0.005: failures.append('audio-timestamps')
    return failures


def analyze(directory, reference, run_id, baseline_offset=None):
    import numpy as np
    data = json.loads((directory / "capture.json").read_text())
    validate_manifest(data, run_id)
    ar, vr = data['audio'], data['video']
    audio = np.fromfile(directory / 'audio.f32le', dtype='<f4').reshape(-1, 2)
    video = np.fromfile(directory / 'video.rgba', dtype=np.uint8).reshape(-1, HEIGHT, WIDTH, 4)
    ref = np.fromfile(reference, dtype=np.uint8).reshape(-1, HEIGHT, WIDTH, 4)
    if len(video) != len(vr) or len(audio) != sum(int(row['frames']) for row in ar):
        raise ValueError('truncated or inconsistent capture')
    audio_measure = measure_audio(ar, audio)
    gain = audio_measure['audioGain']
    shift = audio_measure['audioEnvelopeOffsetSeconds']
    silent = audio_measure['silentFraction']
    frame_errors = []
    pts = []
    for row, frame in zip(vr, video):
        if not 1 < row['pts'] < 9: continue
        index = min(len(ref)-1, max(0, round(row['pts'] * FPS)))
        # Core Image and ffmpeg may have opposite row origins; compare both explicitly.
        expected = ref[index, :, :, :3].astype(float)
        actual = frame[:, :, :3].astype(float)
        frame_errors.append(min(float(np.mean(abs(actual-expected))),
                                float(np.mean(abs(actual[::-1]-expected)))))
        pts.append(row['pts'])
    bad_fraction = float(np.mean(np.array(frame_errors) > 20))
    failures = []
    if silent > 0.03: failures.append('audio-gap')
    if not 0.8 < gain < 1.2: failures.append('audio-gain')
    if offset_mismatch(shift, baseline_offset):
        failures.append('audio-sync')
    if bad_fraction > 0.04: failures.append('video-content')
    if audio_measure['maxTimestampGapSeconds'] > 0.005: failures.append('audio-timestamps')
    result = {"runID": run_id, "failures": failures, "audioGain": gain,
              "audioEnvelopeOffsetSeconds": shift,
              "relativeAudioOffsetSeconds": None if baseline_offset is None else shift-baseline_offset,
              "absoluteAVSync": "unverified: sample-output startup offset remains unresolved",
              "silentFraction": silent,
              "videoBadFraction": bad_fraction, "videoMeanAbsoluteError": float(np.mean(frame_errors)),
              "audioBuffers": len(ar), "videoFrames": len(vr),
              "maxVideoSampleGapSeconds": float(np.max(np.diff(pts))),
              "scope": "decoded signal content; not physical output or HDR acceptance"}
    if (directory/'tap.json').exists():
        result['tap'] = analyze_tap(directory)
        if result['tap']['status'] == 'captured':
            result['decodedMinusTapSeconds'] = shift-result['tap']['audioEnvelopeOffsetSeconds']
    (directory / 'analysis.json').write_text(json.dumps(result, indent=2))
    return result


def analyze_observation(directory, run_id):
    """Coverage and metrics for arbitrary app content; never label natural silence a defect."""
    import numpy as np
    data = json.loads((directory/'capture.json').read_text())
    if data.get('schema') != 1 or data.get('runID') != run_id or data.get('managesPlayback') is not False:
        raise ValueError('stale or non-observer capture')
    start, end, duration = data['initialPosition'], data['position'], data['requestedDurationSeconds']
    if not all(isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)
               for x in [start, end, duration]) or duration <= 0:
        raise ValueError('invalid observation window')
    if end-start < duration-.25:
        raise ValueError('insufficient playback progress')
    if 'audioSequenceGeneration' in data or 'audioSequenceStable' in data:
        generation = data.get('audioSequenceGeneration')
        minimum = 0 if data.get('retainedAudioOutput') is True else -1
        if (type(generation) is not int or generation < minimum or
                data.get('audioSequenceStable') is not True):
            raise ValueError('unstable audio sequence')
    if data['channels'] != 2 or data['sampleRate'] != RATE or data['width'] != WIDTH or data['height'] != HEIGHT:
        raise ValueError('unsupported capture format')
    result = dict(runID=run_id, qualityVerdict='not-evaluated-no-reference',
                  scope='existing-player-decoded-samples-not-speakers', startSeconds=start, endSeconds=end)
    for name, stride in [('audio', 8), ('video', WIDTH*HEIGHT*4)]:
        rows = data[name]
        size = (directory/('audio.f32le' if name == 'audio' else 'video.rgba')).stat().st_size
        offset, previous = 0, None
        for row in rows:
            count = row['frames'] if name == 'audio' else 1
            if count <= 0 or int(count) != count or row['offset'] != offset or not math.isfinite(row['pts']):
                raise ValueError('invalid observer sample metadata')
            if previous is not None and row['pts'] <= previous: raise ValueError('nonmonotonic observer timestamps')
            if name == 'audio' and data.get('retainedAudioOutput') is True and not start <= row['pts'] < start+duration:
                raise ValueError('retained audio outside observation window')
            offset += int(count)*stride; previous = row['pts']
        if size != offset: raise ValueError('truncated observer capture')
        result[name+'Buffers'] = len(rows)
        if not rows:
            result[name+'Coverage'] = 'missing'; continue
        final = rows[-1]['pts'] + (rows[-1]['frames']/RATE if name == 'audio' else 1/FPS)
        result[name+'AcquisitionDelaySeconds'] = rows[0]['pts']-start
        result[name+'Coverage'] = 'captured' if rows[0]['pts'] <= start+.5 and final >= end-.25 else 'partial'
        if name == 'audio':
            samples = np.fromfile(directory/'audio.f32le', dtype='<f4').reshape(-1, 2)
            if not np.isfinite(samples).all(): raise ValueError('nonfinite observer audio')
            result['audioRMSByChannel'] = np.sqrt(np.mean(samples.astype(float)**2, axis=0)).tolist()
            result['audioPeak'] = float(np.max(np.abs(samples)))
            gaps = [b['pts']-(a['pts']+a['frames']/RATE) for a,b in zip(rows, rows[1:])]
        else:
            gaps = [b['pts']-a['pts'] for a,b in zip(rows, rows[1:])]
        result[name+'MaxTimestampGapSeconds'] = max((abs(x) for x in gaps), default=0)
    complete = all(result.get(name+'Coverage') == 'captured' for name in ('audio', 'video'))
    complete &= result.get('audioMaxTimestampGapSeconds', float('inf')) <= .005
    complete &= result.get('videoMaxTimestampGapSeconds', float('inf')) <= .2
    result['evidenceStatus'] = 'complete' if complete else 'partial'
    (directory/'observation.json').write_text(json.dumps(result, indent=2))
    return result


def analyze_tap(directory):
    import numpy as np
    data = json.loads((directory/'tap.json').read_text())
    if data.get('schema') != 1 or data.get('sampleRate') != RATE or data.get('channels') != 2:
        return {'status': 'inconclusive', 'reason': 'unsupported tap schema or format'}
    if data['overflow'] or data['unsupportedFormat']:
        return {'status': 'inconclusive', 'reason': 'tap overflow or unsupported format'}
    try:
        audio = np.fromfile(directory/'tap.f32le', dtype='<f4').reshape(-1, 2)
        measured = measure_audio(data['rows'], audio)
    except (ValueError, OSError) as error:
        return {'status': 'inconclusive', 'reason': str(error)}
    return {'status': 'captured', **measured, 'scope': data['scope'], 'buffers': len(data['rows'])}


def self_test(root):
    """Validate the classifier using independently decoded fixtures, not simulator evidence."""
    results = []
    baseline = None
    for case in CASES:
        run_id = 'offline-' + str(uuid.uuid4())
        directory = root/'runs'/run_id
        directory.mkdir(parents=True)
        ffmpeg('-i', root/case/'index.m3u8', '-t', '10', '-vn', '-f', 'f32le',
               '-ar', str(RATE), '-ac', '2', directory/'audio.f32le')
        ffmpeg('-i', root/case/'index.m3u8', '-t', '10', '-an', '-f', 'rawvideo',
               '-pix_fmt', 'rgba', directory/'video.rgba')
        count = (directory/'audio.f32le').stat().st_size//8
        frames = (directory/'video.rgba').stat().st_size//(WIDTH*HEIGHT*4)
        data = {'schema': 1, 'runID': run_id, 'sampleRate': RATE, 'channels': 2,
                'width': WIDTH, 'height': HEIGHT, 'position': 10,
                'scope': 'offline-classifier-self-test-not-AVPlayer',
                'audio': [{'pts': i/RATE, 'host': i/RATE, 'player': i/RATE,
                           'offset': i*8, 'frames': min(4800, count-i)} for i in range(0, count, 4800)],
                'video': [{'pts': i/FPS, 'host': i/FPS, 'player': i/FPS,
                           'offset': i*WIDTH*HEIGHT*4} for i in range(frames)]}
        (directory/'capture.json').write_text(json.dumps(data))
        result = analyze(directory, root/'reference.rgba', run_id, baseline)
        if case == 'clean': baseline = result['audioEnvelopeOffsetSeconds']
        result.update(case=case, scope=data['scope'], detectorMatchedExpectation=set(result['failures']) == EXPECTED[case])
        results.append(result)
        print(json.dumps(result), flush=True)
    (root/'self-test-results.json').write_text(json.dumps(results, indent=2))
    if not all(r['detectorMatchedExpectation'] for r in results): raise SystemExit(1)


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_): pass


def run(root, cases):
    sim = command([ROOT/'scripts/worktree-sim.sh', '--platform', 'visionos', 'id'], capture_output=True, text=True).stdout.strip()
    devices = json.loads(command(['xcrun', 'simctl', 'list', 'devices', '-j'], capture_output=True, text=True).stdout)
    if any(d['state'] == 'Booted' for group in devices['devices'].values() for d in group):
        raise RuntimeError('simulator lease unavailable: shut down existing simulator first')
    app = ROOT/'build/DerivedData-visionos/Build/Products/Debug-xrsimulator/Labstream.app'
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(QuietHandler, directory=str(root)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    results = []
    baseline_offset = None
    cases = ["clean", *[case for case in cases if case != "clean"]]
    try:
        command(['xcrun', 'simctl', 'boot', sim])
        command(['xcrun', 'simctl', 'bootstatus', sim, '-b'], stdout=subprocess.DEVNULL)
        command(['xcrun', 'simctl', 'install', sim, app])
        container = Path(command(['xcrun', 'simctl', 'get_app_container', sim, 'org.labstream.Labstream', 'data'], capture_output=True, text=True).stdout.strip())
        installed = Path(command(['xcrun', 'simctl', 'get_app_container', sim, 'org.labstream.Labstream', 'app'], capture_output=True, text=True).stdout.strip())
        def binary_uuid(path):
            return command(['xcrun', 'dwarfdump', '--uuid', path/'Labstream'], capture_output=True, text=True).stdout.split()[1]
        if binary_uuid(app) != binary_uuid(installed): raise RuntimeError('wrong installed binary')
        for case in cases:
            run_id = str(uuid.uuid4())
            subprocess.run(['xcrun', 'simctl', 'terminate', sim, 'org.labstream.Labstream'], capture_output=True)
            url = f'http://127.0.0.1:{server.server_port}/{case}/index.m3u8'
            command(['xcrun', 'simctl', 'launch', sim, 'org.labstream.Labstream',
                     '--vp-probe-play-url', url, '--vp-probe-capture-signals', run_id], stdout=subprocess.DEVNULL)
            source = container/'Documents/SignalCaptures'
            deadline = time.monotonic()+75
            while time.monotonic() < deadline:
                manifest = source/'capture.json'
                if manifest.exists() and json.loads(manifest.read_text()).get('runID') == run_id: break
                time.sleep(0.5)
            else: raise RuntimeError(f'{case}: no current-run capture within 75 seconds')
            destination = root/'runs'/run_id
            shutil.copytree(source, destination)
            try:
                result = analyze(destination, root/'reference.rgba', run_id, baseline_offset)
            except (ValueError, OSError) as error:
                results.append({'case': case, 'runID': run_id, 'status': 'inconclusive', 'reason': str(error)})
                raise
            if case == 'clean':
                if result['failures']:
                    results.append(result)
                    raise RuntimeError('clean reference failed; refusing to calibrate')
                baseline_offset = result['audioEnvelopeOffsetSeconds']
            result['case'] = case
            result['detectorMatchedExpectation'] = set(result['failures']) == EXPECTED[case]
            results.append(result)
            print(json.dumps(result), flush=True)
        command(['xcrun', 'simctl', 'io', sim, 'screenshot', root/'smoke.png'], stdout=subprocess.DEVNULL)
    finally:
        server.shutdown()
        server.server_close()
        subprocess.run(['xcrun', 'simctl', 'terminate', sim, 'org.labstream.Labstream'], capture_output=True)
        subprocess.run(['xcrun', 'simctl', 'shutdown', sim], capture_output=True)
        (root/'results.json').write_text(json.dumps(results, indent=2))
    if not all(r['detectorMatchedExpectation'] for r in results): raise SystemExit(1)


def compile_host(root):
    executable = root/'signal-host'
    command(['xcrun', 'swiftc', '-D', 'DEBUG', '-D', 'SIGNAL_LAB_HOST', '-parse-as-library',
             '-target', 'arm64-apple-macos27.0',
             ROOT/'Labstream/Shared/Debug/DebugPlaybackSignalCapture.swift',
             ROOT/'Labstream/Shared/Debug/DebugPlaybackAudioTap.swift',
             ROOT/'scripts/playback-signal-host.swift', '-o', executable])
    return executable


def run_host(root, cases):
    """Exercise the shared capture method in an isolated macOS run-loop process."""
    executable = compile_host(root)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(QuietHandler, directory=str(root)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    results, baseline, tap_baseline = [], None, None
    try:
        for case in ['clean', *[case for case in cases if case != 'clean']]:
            run_id = 'host-' + str(uuid.uuid4())
            directory = root/'runs'/run_id
            try:
                command([executable, f'http://127.0.0.1:{server.server_port}/{case}/index.m3u8',
                         directory, run_id], timeout=60)
                result = analyze(directory, root/'reference.rgba', run_id, baseline)
            except (ValueError, OSError, subprocess.SubprocessError) as error:
                results.append({'case': case, 'runID': run_id, 'status': 'inconclusive', 'reason': str(error)})
                raise
            if case == 'clean':
                if result['failures']:
                    results.append(result)
                    raise RuntimeError('clean reference failed; refusing to calibrate')
                baseline = result['audioEnvelopeOffsetSeconds']
            result.update(case=case, platform='standalone-macos-host',
                          detectorMatchedExpectation=set(result['failures']) == EXPECTED[case])
            if os.environ.get('SIGNAL_LAB_AUDIO_TAP') == '1':
                tap = result.get('tap', {})
                if tap.get('status') != 'captured':
                    raise ValueError('requested audio tap did not produce complete evidence')
                if case == 'clean':
                    if audio_failures(tap): raise ValueError('clean audio tap failed')
                    tap_baseline = tap['audioEnvelopeOffsetSeconds']
                tap['failures'] = audio_failures(tap, tap_baseline)
                tap['detectorMatchedExpectation'] = set(tap['failures']) == (EXPECTED[case] - {'video-content'})
                result['detectorMatchedExpectation'] &= tap['detectorMatchedExpectation']
            results.append(result)
            print(json.dumps(result), flush=True)
    finally:
        server.shutdown()
        server.server_close()
        (root/'host-results.json').write_text(json.dumps(results, indent=2))
    if not all(r['detectorMatchedExpectation'] for r in results): raise SystemExit(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['generate', 'run', 'run-host', 'self-test'])
    parser.add_argument('--output', type=Path, default=ROOT/'build/av-quality')
    parser.add_argument('--case', choices=CASES, action='append')
    args = parser.parse_args()
    root = args.output.resolve()
    if not root.is_relative_to(ROOT/'build'):
        parser.error('output must remain under the gitignored build directory')
    if args.action == 'generate': generate(root)
    elif args.action == 'self-test': self_test(root)
    elif args.action == 'run-host': run_host(root, args.case or CASES)
    else: run(root, args.case or CASES)


if __name__ == '__main__': main()
