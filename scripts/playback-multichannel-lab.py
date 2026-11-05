#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "imageio-ffmpeg"]
# ///
"""Known 5.1 channel identities through AVPlayer; no physical speaker claims."""
import argparse
import functools
import hashlib
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
LABELS = ['FL', 'FR', 'FC', 'LFE', 'SL', 'SR']
FREQUENCIES = [400, 600, 800, 60, 1000, 1200]
PROFILES = [('aac', 'aac', 'fmp4'), ('aac-back', 'aac', 'fmp4'), ('ac3', 'ac3', 'fmp4'), ('eac3', 'eac3', 'fmp4'),
            ('dts', 'dca', 'mpegts'), ('truehd', 'truehd', 'mpegts'), ('pcm', 'pcm_s16le', 'fmp4')]


def source():
    import numpy as np
    t = np.arange(12*48000)/48000
    return np.stack([0.1*np.sin(2*np.pi*f*t) for f in FREQUENCIES], axis=1).astype('<f4')


def measure(samples):
    import numpy as np
    if samples.ndim != 2 or samples.shape[1] not in (2, 6) or len(samples) < 10*48000 or not np.isfinite(samples).all():
        raise ValueError('incomplete or unsupported PCM')
    window = samples[48000:9*48000]
    spectrum = np.abs(np.fft.rfft(window, axis=0))*2/len(window)
    gains = np.stack([spectrum[round(f*len(window)/48000)]/0.1 for f in FREQUENCIES], axis=1)
    failures = []
    if samples.shape[1] == 6:
        for i, label in enumerate(LABELS):
            if not 0.8 < gains[i, i] < 1.2: failures.append(label+'-level-or-missing')
        off = gains.copy()
        np.fill_diagonal(off, 0)
        if np.max(off) > 0.15: failures.append('channel-leak-or-swap')
        scope = 'requested-5.1-decoded-channel-routing-not-speakers'
    else:
        # Center must reach both sides; side channels must retain left/right identity.
        # LFE inclusion and exact downmix coefficients depend on policy and are only measured.
        for i, side in [(0, 0), (1, 1), (4, 0), (5, 1)]:
            if gains[side, i] < 0.15 or gains[1-side, i] > gains[side, i]*0.25:
                failures.append(LABELS[i]+'-downmix-routing')
        if min(gains[:, 2]) < 0.15 or abs(gains[0, 2]-gains[1, 2]) > 0.15:
            failures.append('center-downmix-routing')
        scope = 'stereo-downmix-routing-LFE-policy-unverified-not-speakers'
    return dict(failures=failures, outputBySourceGain=gains.astype(float).round(5).tolist(),
                dominantSourcePerSlot=[LABELS[int(i)] for i in np.argmax(gains, axis=1)],
                sourceChannels=LABELS, outputChannels=LABELS if samples.shape[1] == 6 else ['L', 'R'], scope=scope)


def self_test():
    import numpy as np
    clean = source()
    assert not measure(clean)['failures']
    swapped = clean[:, [1, 0, 2, 3, 4, 5]]
    assert 'channel-leak-or-swap' in measure(swapped)['failures']
    missing = clean.copy(); missing[:, 2] = 0
    assert 'FC-level-or-missing' in measure(missing)['failures']
    stereo = np.stack([clean[:, 0]+0.707*(clean[:, 2]+clean[:, 4]),
                       clean[:, 1]+0.707*(clean[:, 2]+clean[:, 5])], axis=1)
    assert not measure(stereo)['failures']
    assert measure(stereo[:, ::-1])['failures']
    try: measure(clean[:100])
    except ValueError: pass
    else: raise AssertionError('incomplete data admitted')


def generate(root):
    import imageio_ffmpeg
    root.mkdir(parents=True, exist_ok=True)
    source().tofile(root/'source.f32le')
    _, video = lab.reference_signals()
    video.tofile(root/'source.rgb')
    manifest = dict(schema=1, sourceChannels=LABELS, frequenciesHz=FREQUENCIES, profiles=[])
    try:
        for name, encoder, container in PROFILES:
            directory = root/name; directory.mkdir(exist_ok=True)
            record = dict(name=name, encoder=encoder, container=container)
            args = [imageio_ffmpeg.get_ffmpeg_exe(), '-hide_banner', '-y', '-f', 'rawvideo',
                    '-pix_fmt', 'rgb24', '-s', '160x90', '-r', '30', '-i', root/'source.rgb',
                    '-f', 'f32le', '-ar', '48000', '-ac', '6', '-channel_layout', '5.1(side)',
                    '-i', root/'source.f32le', '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
                    '-preset', 'fast', '-g', '30', '-bf', '0', '-c:a', encoder, '-strict', '-2']
            if name == 'aac-back': args += ['-channel_layout', '5.1']
            if name in ('aac', 'aac-back', 'ac3', 'eac3', 'dts'): args += ['-b:a', '768k' if name == 'dts' else '384k']
            args += ['-f', 'hls', '-hls_time', '1', '-hls_list_size', '0', '-hls_segment_type', container, directory/'index.m3u8']
            try:
                with (directory/'generation.log').open('w') as log:
                    lab.command(args, stdout=log, stderr=subprocess.STDOUT)
                info = lab.command([imageio_ffmpeg.get_ffmpeg_exe(), '-hide_banner', '-i', directory/'index.m3u8',
                                    '-map', '0:a:0', '-c', 'copy', '-f', 'null', '-'], capture_output=True, text=True)
                record.update(status='generated', streams=[line.strip() for line in info.stderr.splitlines() if 'Audio:' in line],
                    files={str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                           for p in directory.iterdir() if p.suffix in ('.m3u8', '.mp4', '.m4s', '.ts')})
            except subprocess.SubprocessError:
                record.update(status='generation-failed', reason='encoder/muxer or audio-stream admission failed; not a player verdict')
            manifest['profiles'].append(record)
    finally:
        (root/'source.f32le').unlink(missing_ok=True)
        (root/'source.rgb').unlink(missing_ok=True)
        (root/'manifest.json').write_text(json.dumps(manifest, indent=2))
    return manifest


def run(root, profiles=None, channel_counts=(6, 2)):
    import numpy as np
    self_test()
    manifest = json.loads((root/'manifest.json').read_text())
    executable = lab.compile_host(root)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(lab.QuietHandler, directory=str(root)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    results = []
    try:
        for profile in manifest['profiles']:
            if profiles and profile['name'] not in profiles: continue
            if profile['status'] != 'generated':
                results.append(profile); continue
            if any(hashlib.sha256((root/path).read_bytes()).hexdigest() != digest for path, digest in profile['files'].items()):
                raise ValueError('fixture changed since generation')
            import imageio_ffmpeg
            decoded = lab.command([imageio_ffmpeg.get_ffmpeg_exe(), '-v', 'error', '-i', root/profile['name']/'index.m3u8',
                                   '-map', '0:a:0', '-ar', '48000', '-ac', '6', '-f', 'f32le', '-'], capture_output=True)
            oracle = measure(np.frombuffer(decoded.stdout, dtype='<f4').reshape(-1, 6))
            if oracle['failures']:
                results.append(dict(profile=profile['name'], status='fixture-invalid', offlineReference=oracle)); continue
            for channels in channel_counts:
                rid = str(uuid.uuid4()); directory = root/'runs'/rid
                result = dict(profile=profile['name'], requestedChannels=channels, runID=rid, offlineReference=oracle)
                try:
                    lab.command([executable, f'http://127.0.0.1:{server.server_port}/{profile["name"]}/index.m3u8', directory, rid],
                        env=dict(os.environ, SIGNAL_LAB_CHANNELS=str(channels), SIGNAL_LAB_AUDIO_TAP='0', SIGNAL_LAB_DISABLE_DECODED_AUDIO='0'),
                        capture_output=True, text=True, timeout=45)
                    data = json.loads((directory/'capture.json').read_text())
                    rows = data['audio']
                    if data['runID'] != rid or data['channels'] != channels or data['sampleRate'] != 48000 or not rows:
                        raise ValueError('missing or mismatched capture')
                    offset = 0; previous = None
                    for row in rows:
                        if row['frames'] <= 0 or int(row['frames']) != row['frames'] or row['offset'] != offset or not np.isfinite(row['pts']):
                            raise ValueError('invalid sample metadata')
                        if previous is not None and abs(row['pts']-previous) > .005: raise ValueError('discontinuous audio timestamps')
                        offset += int(row['frames'])*channels*4
                        previous = row['pts']+row['frames']/48000
                    if (directory/'audio.f32le').stat().st_size != offset: raise ValueError('truncated PCM')
                    samples = np.fromfile(directory/'audio.f32le', dtype='<f4').reshape(-1, channels)
                    result.update(measure(samples))
                    result['status'] = 'routing-mismatch' if result['failures'] else 'routing-pass'
                    result['observedChannelLayoutTags'] = data.get('observedChannelLayoutTags', [])
                    result['requestedChannelLayoutTag'] = data.get('requestedChannelLayoutTag')
                    if channels == 6 and not result['observedChannelLayoutTags']:
                        result.update(status='layout-unverified', outputChannels=['slot'+str(i+1) for i in range(6)],
                                      requestedOutputChannels=LABELS,
                                      reason='sample layout metadata absent; measured slot order is not an accepted speaker mapping')
                except subprocess.CalledProcessError as error:
                    result.update(status='capture-failed', reason=error.stdout.strip()[-500:])
                except (ValueError, OSError, subprocess.TimeoutExpired) as error:
                    result.update(status='inconclusive', reason=str(error)[:300])
                results.append(result)
                (root/'results.json').write_text(json.dumps(results, indent=2))
                print(json.dumps(result), flush=True)
    finally:
        server.shutdown(); server.server_close()
        (root/'results.json').write_text(json.dumps(results, indent=2))
        archive = root/'reports'; archive.mkdir(exist_ok=True)
        (archive/(str(uuid.uuid4())+'.json')).write_text(json.dumps(results, indent=2))
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['generate', 'run', 'self-test'])
    parser.add_argument('--profile', action='append', choices=[p[0] for p in PROFILES])
    parser.add_argument('--channels', action='append', type=int, choices=(2, 6))
    parser.add_argument('--output', type=Path, default=lab.ROOT/'build/av-multichannel')
    args = parser.parse_args(); root = args.output.resolve()
    if not root.is_relative_to(lab.ROOT/'build'): parser.error('output must be under build/')
    if args.action == 'generate': generate(root)
    elif args.action == 'self-test': self_test(); print('channel detector self-test passed')
    else:
        results = run(root, args.profile, args.channels or (6, 2))
        if any(row.get('status') != 'routing-pass' for row in results): raise SystemExit(1)

if __name__ == '__main__': main()
