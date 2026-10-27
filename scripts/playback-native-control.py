#!/usr/bin/env python3
"""Bounded generated-fixture native controls; never a backend/credential runner."""
from __future__ import annotations
import argparse
import base64
from collections import Counter
from datetime import datetime, timezone
import hashlib
import http.server
import json
import math
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import threading
import time
import urllib.parse
import uuid

ROOT = Path(__file__).resolve().parents[1]
MODES = ('tap-mixed', 'tap-asset', 'retained', 'lifecycle')
SOURCE_PATHS = (
    'Labstream/Shared/Debug/DebugPlaybackAudioTap.swift',
    'Labstream/Shared/Debug/DebugPlaybackSignalCapture.swift',
    'Labstream/Shared/Debug/DebugRawURLPlaybackProbe.swift',
    'Labstream/Shared/Debug/DebugPlaybackScenario.swift',
    'Labstream/Shared/Debug/DebugPlaybackEvidence.swift',
    'Labstream/Shared/Debug/DebugPlaybackProbeSupport.swift',
    'Labstream/Shared/Debug/DebugJellyfinPlaybackProbe.swift',
    'Labstream/Shared/App/ContentView.swift',
    'Labstream/Shared/Player/PlaybackController.swift',
    'scripts/playback-signal-host.swift',
)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_app(app, root=ROOT):
    app = Path(app).resolve()
    stage = (root / 'build/macos-host').resolve()
    if not app.is_relative_to(stage) or app.name != 'Labstream.app':
        raise ValueError('app_must_be_worktree_staged')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    identity = info.get('CFBundleIdentifier', '')
    if not identity.startswith('org.labstream.Labstream.dev.') or identity != 'org.labstream.Labstream.dev.' + app.parent.name:
        raise ValueError('isolated_identity_required')
    exe = app / 'Contents/MacOS/Labstream'
    if info.get('CFBundleExecutable') != 'Labstream' or not exe.is_file():
        raise ValueError('invalid_executable')
    return app, exe, identity


def validate_fixture(fixture, mode, root=ROOT):
    path = Path(fixture).resolve()
    if not path.is_relative_to((root / 'build/av-quality').resolve()) or not path.is_file():
        raise ValueError('generated_fixture_required')
    expected = '.mp4' if mode.startswith('tap-') else '.m3u8'
    if path.suffix.lower() != expected:
        raise ValueError('fixture_transport_mismatch')
    return path


def fixture_files(fixture):
    """Hash and serve only this explicit local fixture and its HLS dependencies."""
    root = fixture.parent.resolve()
    pending, files = [fixture.resolve()], {}
    while pending:
        path = pending.pop()
        if not path.is_relative_to(root) or not path.is_file() or path.suffix not in ('.mp4', '.m3u8', '.m4s', '.ts'):
            raise ValueError('invalid_fixture_dependency')
        key = str(path.relative_to(root))
        if key in files: continue
        if len(files) >= 256: raise ValueError('fixture_dependency_limit')
        files[key] = sha(path)
        if path.suffix == '.m3u8':
            if path.stat().st_size > 65536: raise ValueError('playlist_too_large')
            for line in path.read_text().splitlines():
                line = line.strip()
                refs = re.findall(r'URI="([^"]+)"', line) if line.startswith('#') else [line] if line else []
                for ref in refs:
                    url = urllib.parse.urlsplit(ref)
                    if url.scheme or url.netloc or url.query or url.fragment: raise ValueError('nonlocal_fixture_dependency')
                    pending.append((path.parent / urllib.parse.unquote(url.path)).resolve())
    return dict(sorted(files.items()))


def verify_build(attestation, exe, sources):
    if attestation is None: return False
    data = json.loads(Path(attestation).read_text())
    built = datetime.fromisoformat(data['builtAtUTC'].replace('Z', '+00:00'))
    if (data.get('schemaVersion') != 1 or data.get('cleanBuild') is not True or built.tzinfo is None or
            built.timestamp() > time.time() + 60 or built.timestamp() < exe.stat().st_mtime - 5 or
            data.get('executableSHA256') != sha(exe) or data.get('sourceSHA256') != sources):
        raise ValueError('build_attestation_mismatch')
    return True


def classify_events(events, mode):
    """Completion is not acceptance: every requested phase needs its own evidence."""
    tap = mode.startswith('tap-')
    labels = ['tap-initial', 'tap-forward', 'tap-backward'] if tap else (
        ['control-initial', 'control-forward', 'control-backward', 'control-replacement']
        if mode == 'lifecycle' else ['control-initial', 'control-second'])
    results, previous_epoch = [], None
    for label in labels:
        rows = [e for e in events if e.get('kind') == ('tap' if tap else 'observation') and e.get('window') == label]
        row = rows[0] if len(rows) == 1 else {}
        def finite(key, minimum, maximum):
            value = row.get(key)
            return type(value) in (int, float) and math.isfinite(value) and minimum <= value <= maximum
        passed = (row.get('audioCoverage') == 'captured' and finite('audioBuffers', 1, 100000) and
                  finite('observedSeconds', 7.75, 25) and finite('audioMaxTimestampGapSeconds', 0, .005))
        if tap:
            passed &= row.get('epochStable') is True and all(row.get(k) is False for k in ('overflow', 'unsupportedFormat', 'invalidTime'))
            epoch = row.get('streamEpoch')
            passed &= type(epoch) is int and epoch >= 0
            if label != 'tap-initial': passed &= previous_epoch is not None and type(epoch) is int and epoch > previous_epoch
            previous_epoch = epoch if type(epoch) is int else None
        else:
            passed &= row.get('audioSequenceStable') is True
            if label in ('control-forward', 'control-backward'):
                passed &= any(e.get('stage') == label and e.get('outcome') == 'seekRestartAcknowledged' for e in events)
        results.append(dict(case=label, status='pass' if passed else 'inconclusive',
            scope='seek-freshness' if label.endswith(('forward', 'backward')) else 'decoded-audio-coverage',
            reason='bounded audio coverage verified' if passed else 'required audio or freshness evidence unavailable'))
    if mode == 'lifecycle':
        for stage, outcome in [('itemReplacement', 'oldOwnerRejected'), ('cancellation', 'cancelledNoManifestOutputDetached')]:
            matches = [e for e in events if e.get('stage') == stage and e.get('outcome') == outcome]
            results.append(dict(case=stage, status='pass' if len(matches) == 1 else 'inconclusive',
                scope='capture-cleanup', reason='owned capture lifecycle verified' if len(matches) == 1 else 'cleanup evidence unavailable'))
    return results


class RangeHandler(http.server.BaseHTTPRequestHandler):
    """Serve only generated media siblings, with strict single-range support."""
    def log_message(self, *_):
        pass

    def do_HEAD(self):
        self.serve(False)

    def do_GET(self):
        self.serve(True)

    def serve(self, body):
        parsed = urllib.parse.urlsplit(self.path)
        root = self.server.fixture_root.resolve()
        path = (root / urllib.parse.unquote(parsed.path).lstrip('/')).resolve()
        if parsed.query or not path.is_relative_to(root) or str(path.relative_to(root)) not in self.server.allowed_files or not path.is_file():
            self.send_error(404); return
        size = path.stat().st_size
        first, last, status = 0, size - 1, 200
        requested = self.headers.get('Range')
        if requested:
            match = re.fullmatch(r'bytes=(\d*)-(\d*)', requested)
            if not match or not any(match.groups()):
                self.send_error(416); return
            lo, hi = match.groups()
            if lo:
                first = int(lo); last = min(int(hi), size - 1) if hi else size - 1
            else:
                first = max(0, size - int(hi))
            if first > last or first >= size:
                self.send_response(416); self.send_header('Content-Range', f'bytes */{size}'); self.end_headers(); return
            status = 206
        self.send_response(status)
        self.send_header('Content-Type', 'application/vnd.apple.mpegurl' if path.suffix == '.m3u8' else 'video/mp4')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(last - first + 1))
        if status == 206:
            self.send_header('Content-Range', f'bytes {first}-{last}/{size}')
        self.end_headers()
        if body:
            try:
                with path.open('rb') as source:
                    source.seek(first)
                    remaining = last - first + 1
                    while remaining:
                        chunk = source.read(min(65536, remaining))
                        if not chunk: break
                        self.wfile.write(chunk); remaining -= len(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass


def exact_pids(exe):
    result = []
    for line in subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and fields[1] == str(exe): result.append(int(fields[0]))
    return result


def stop_exact(pid, exe):
    if pid not in exact_pids(exe): return
    subprocess.run(['kill', '-TERM', str(pid)], check=False, capture_output=True)
    for _ in range(30):
        if pid not in exact_pids(exe): return
        time.sleep(.1)
    raise ValueError('owned_process_did_not_stop')


def decode_events(raw, run_id, supplemental_raw=None):
    """Reassemble bounded intended fragments; ignore other process/system fields."""
    seen, messages, events = set(), [], []
    for line in raw.splitlines():
        try: row = json.loads(line)
        except json.JSONDecodeError: continue
        message = row.get('eventMessage', '')
        identity = (row.get('timestamp'), message)
        if identity in seen: continue
        seen.add(identity)
        messages.append(message)
    if supplemental_raw is not None:
        # log stream and log show format timestamps differently. Merge their
        # message multisets, preserving repeated events within either source.
        remaining = Counter(messages)
        for line in supplemental_raw.splitlines():
            try: row = json.loads(line)
            except json.JSONDecodeError: continue
            message = row.get('eventMessage', '')
            if remaining[message]: remaining[message] -= 1
            else: messages.append(message)
    pieces, expected = [], 0
    for message in messages:
        if message.startswith('evidence.tap.part '):
            match = re.fullmatch(r'evidence\.tap\.part index=(\d+) count=(\d+) payload=([A-Za-z0-9+/=]{1,512})', message)
            if not match: raise ValueError('invalid_tap_fragment')
            index, count = map(int, match.groups()[:2])
            if not 1 <= count <= 12: raise ValueError('unbounded_tap_fragment')
            if index == 0: pieces, expected = [], count
            if count != expected or index != len(pieces): raise ValueError('incomplete_tap_fragments')
            pieces.append(match[3])
            if len(pieces) == count:
                value = json.loads(base64.b64decode(''.join(pieces), validate=True))
                if value.get('runID') != run_id or value.get('schemaVersion') != 1: raise ValueError('stale_tap_summary')
                events.append(dict(kind='tap', **value)); pieces, expected = [], 0
        for prefix, kind in (('evidence.observation payload=', 'observation'), ('evidence.lifecycle payload=', 'lifecycle')):
            if message.startswith(prefix):
                value = json.loads(message[len(prefix):])
                if value.get('runID') != run_id: raise ValueError('stale_observation')
                events.append(dict(kind=kind, **value))
    if pieces: raise ValueError('incomplete_tap_fragments')
    completed = 'probe.tap_control.complete' in messages or 'probe.observer_control.complete' in messages
    failed = any(x in messages for x in ('probe.tap_control.failed', 'probe.tap_control.not_ready', 'probe.observer_control.failed', 'probe.observer_control.not_ready'))
    return events, completed, failed


def plan(app, fixture, mode):
    return {'schemaVersion': 1, 'action': 'plan', 'mode': mode, 'app': str(app),
            'fixture': str(fixture), 'network': 'ephemeral loopback generated-media only',
            'effects': 'terminates exact staged process; generated control; restores normal app',
            'qualityVerdict': 'not-evaluated-no-reference'}


def run_control(app, exe, identity, fixture, mode, timeout, build_attestation=None):
    run_id = str(uuid.uuid4()).upper()
    output = ROOT / 'build/av-quality/native-control-runs' / run_id
    output.mkdir(parents=True, exist_ok=False)
    sources = {name: sha(ROOT / name) for name in SOURCE_PATHS if (ROOT / name).exists()}
    verified_build = verify_build(build_attestation, exe, sources)
    files = fixture_files(fixture)
    if any((ROOT / name).stat().st_mtime > exe.stat().st_mtime for name in sources if name.endswith('.swift') and name.startswith('Labstream/')):
        raise ValueError('stale_app_rebuild_required')
    metadata = {'schemaVersion': 1, 'runID': run_id,
        'captureDate': datetime.now(timezone.utc).isoformat(), 'mode': mode,
        'sourceSHA256': sources, 'fixtureSHA256': sha(fixture), 'fixtureFilesSHA256': files,
        'cleanBuildAttested': verified_build,
        'app': {'executableSHA256': sha(exe), 'identity': identity},
        'qualityVerdict': 'not-evaluated-no-reference', 'events': []}
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), RangeHandler)
    server.daemon_threads = True; server.fixture_root = fixture.parent; server.allowed_files = set(files)
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    stream, stream_file, pid = None, None, None
    try:
        for old in exact_pids(exe): stop_exact(old, exe)
        args = ['--vp-probe-play-url', f'http://127.0.0.1:{server.server_port}/{fixture.name}']
        if mode.startswith('tap-'):
            args += ['--vp-probe-tap-control', run_id, '--vp-probe-tap-track', mode.removeprefix('tap-')]
        else:
            args += ['--vp-probe-observer-control', run_id, '--vp-probe-retain-observer-audio']
            if mode == 'lifecycle': args += ['--vp-probe-observer-lifecycle']
        subprocess.run(['open', '-n', str(app), '--args', *args], check=True, capture_output=True)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            pids = exact_pids(exe)
            if len(pids) == 1: pid = pids[0]; break
            time.sleep(.1)
        if pid is None: raise ValueError('exact_process_unavailable')
        metadata['app'].update(pid=pid, exactExecutableVerified=True)
        predicate = f'processID == {pid} AND (category == "PlaybackEvidence" OR category == "RawURLProbe")'
        stream_file = (output / 'exact-pid-stream.ndjson').open('w')
        stream = subprocess.Popen(['/usr/bin/log', 'stream', '--style', 'ndjson', '--level', 'info', '--predicate', predicate], stdout=stream_file, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + timeout
        raw = ''
        while time.monotonic() < deadline:
            raw = (output / 'exact-pid-stream.ndjson').read_text()
            if len(raw) > 512 * 1024: raise ValueError('unbounded_intended_log')
            if any(x in raw for x in ('probe.tap_control.complete', 'probe.tap_control.failed', 'probe.tap_control.not_ready', 'probe.observer_control.complete', 'probe.observer_control.failed', 'probe.observer_control.not_ready')): break
            time.sleep(.25)
        # Delayed visibility is not an app failure. One final exact-PID bounded pull.
        pull = subprocess.run(['/usr/bin/log', 'show', '--last', f'{math.ceil((timeout+15)/60)}m', '--info', '--style', 'ndjson', '--predicate', predicate], capture_output=True, text=True, timeout=20)
        (output / 'exact-pid-show.ndjson').write_text(pull.stdout)
        events, completed, failed = decode_events(raw, run_id, pull.stdout)
        metadata.update(events=events, executionStatus='completed' if completed else 'failed' if failed else 'inconclusive-log-visibility')
        metadata['sourcesUnchanged'] = all(sha(ROOT / name) == value for name, value in sources.items())
        metadata['fixturesUnchanged'] = fixture_files(fixture) == files
        metadata['executableUnchanged'] = sha(exe) == metadata['app']['executableSHA256']
        metadata['results'] = classify_events(events, mode)
        metadata['status'] = 'pass' if (completed and not failed and verified_build and metadata['sourcesUnchanged'] and
            metadata['fixturesUnchanged'] and metadata['executableUnchanged'] and
            all(r['status'] == 'pass' for r in metadata['results'])) else 'inconclusive'
    finally:
        if stream is not None:
            stream.terminate()
            try: stream.wait(timeout=3)
            except subprocess.TimeoutExpired: stream.kill(); stream.wait()
        if stream_file: stream_file.close()
        server.shutdown(); server.server_close(); thread.join(timeout=3)
        if pid is not None: stop_exact(pid, exe)
        normal = subprocess.run(['open', '-n', str(app)], capture_output=True)
        metadata['normalRelaunchRequested'] = normal.returncode == 0
        if normal.returncode != 0: metadata['status'] = 'inconclusive'
        if metadata.get('results') is not None:
            for result in metadata['results']: result['case'] = result['case'].lower()
            if (metadata.get('executionStatus') != 'completed' or not metadata.get('sourcesUnchanged') or
                    not metadata.get('fixturesUnchanged') or not metadata.get('executableUnchanged') or normal.returncode != 0):
                metadata['results'].append(dict(case='native-harness', status='inconclusive', scope='capture-cleanup',
                    reason='native control did not complete its final checks'))
        (output / 'metadata.json').write_text(json.dumps(metadata, indent=2, allow_nan=False))
        if (verified_build and metadata.get('sourcesUnchanged') and metadata.get('executableUnchanged') and
                metadata.get('results') is not None and metadata['app'].get('exactExecutableVerified') is True):
            envelope = dict(schemaVersion=1, kind='native-evidence', runID=run_id,
                capturedAtUTC=metadata['captureDate'], sourceSHA256=sources,
                app={key: metadata['app'][key] for key in ('executableSHA256', 'pid', 'exactExecutableVerified')},
                artifact=dict(path='metadata.json', sha256=sha(output / 'metadata.json')), results=metadata['results'])
            (output / 'envelope.json').write_text(json.dumps(envelope, indent=2, allow_nan=False))
    print(json.dumps({'runID': run_id, 'metadata': str(output / 'metadata.json'), 'executionStatus': metadata.get('executionStatus', 'inconclusive')}, indent=2))
    return 0 if metadata.get('status') == 'pass' and metadata.get('sourcesUnchanged') and metadata.get('fixturesUnchanged') else 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('plan', 'run'))
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--fixture', required=True, type=Path)
    parser.add_argument('--mode', required=True, choices=MODES)
    parser.add_argument('--timeout', type=int, default=120)
    parser.add_argument('--allow-native', action='store_true')
    parser.add_argument('--build-attestation', type=Path)
    args = parser.parse_args()
    try:
        app, exe, identity = validate_app(args.app)
        fixture = validate_fixture(args.fixture, args.mode)
        if not 30 <= args.timeout <= 180: raise ValueError('invalid_timeout')
        if args.action == 'plan': print(json.dumps(plan(app, fixture, args.mode), indent=2)); return 0
        if not args.allow_native: raise ValueError('native_execution_requires_allow_native')
        return run_control(app, exe, identity, fixture, args.mode, args.timeout, args.build_attestation)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(json.dumps({'schemaVersion': 1, 'status': 'inconclusive', 'reason': type(error).__name__}))
        return 2

if __name__ == '__main__':
    raise SystemExit(main())
