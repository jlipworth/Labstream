#!/usr/bin/env python3
"""Repeat the Emby deep-seek reopen probe on the Mac host and correlate Emby's server log.

Each run relaunches the worktree-staged dev app with the in-app Emby seek scenario, waits
for probe.pass/probe.fail, then counts app-side signals (prewarm, copy-lane retry, render
pipeline failures, audio-queue resyncs, discarded audio buffers) and server-side transcode
starts from the lines Emby appended during that run. The app must already be signed in to
Emby; this runner never authenticates. Raw per-run logs stay under the gitignored output
directory; the printed summary carries no titles, item IDs, URLs or tokens.
"""
from __future__ import annotations

import argparse
from datetime import datetime
import json
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_APP = ROOT / 'build/macos-host/downloads-overhaul/Labstream.app'
DEFAULT_SEEKS_MS = (2_400_000, 1_200_000, 3_600_000, 1_800_000, 4_800_000, 600_000, 3_000_000, 4_200_000)
SERVER_LOG = '/config/logs/embyserver.txt'

APP_SIGNALS = {
    'reopens': re.compile(r'seek: remote stream re-open'),
    'copy_child_verified': re.compile(r'remote\.copy_child_verified backend=emby'),
    'copy_reopen_retry': re.compile(r'remote\.emby_copy_reopen_retry'),
    'render_pipeline_failure': re.compile(r'Could not create render pipeline'),
    'aq_resync': re.compile(r'Resyncing AQ timeline'),
    'audio_discarded': re.compile(r'sbufIsOld'),
}
# NSLog does not reach the unified log for the hosted dev app; prewarm facts come from the
# app's own diagnostics JSONL, filtered to the run's process.
DIAGNOSTICS = Path.home() / 'Library/Containers/org.labstream.Labstream.dev.{identity}/Data/Library/Application Support/Labstream/Diagnostics/app-diagnostics.jsonl'
SERVER_SIGNALS = {
    'transcode_starts': re.compile(r'Starting transcoding because'),
    'starts_index_null': re.compile(r'Starting transcoding because currentTranscodingIndex=null'),
    'gap_restarts': re.compile(r'Starting transcoding because (?:segmentGap|requestedIndex)'),
}
# Each open legitimately starts one job and may restart it once at the seek target. A run
# with more gap restarts than this has Emby restarting its encoder segment after segment.
RESTART_STORM_THRESHOLD = 6
SECRET_QUERY = re.compile(r'(?i)\b(api_key|x-emby-token|playsessionid|deviceid|mediasourceid)=[^&\s"]+')
PROBE_RESULT = re.compile(r'probe\.(pass|fail)\b(.*)')


def redact(line: str) -> str:
    return SECRET_QUERY.sub(lambda m: f'{m.group(1)}=<redacted>', line)


def count_signals(lines, patterns) -> dict[str, int]:
    return {name: sum(1 for line in lines if pattern.search(line)) for name, pattern in patterns.items()}


def count_diagnostics(records, pids) -> dict[str, int]:
    """Prewarm/proxy/retry facts for the given app processes from diagnostics records."""
    counts = dict(prewarm_ran=0, prewarm_fetched_media_as_master=0, target_warm_ready=0,
                  target_warm_other=0, diag_copy_reopen_retry=0, proxy_opened=0)
    for record in records:
        fields = record.get('fields') or {}
        if fields.get('process_id') not in pids:
            continue
        name = record.get('name')
        if name == 'playback.remote_prewarm':
            counts['prewarm_ran'] += 1
        elif name == 'playback.remote_prewarm_phase' and fields.get('phase') == 'master' \
                and fields.get('playlist_kind') == 'media':
            counts['prewarm_fetched_media_as_master'] += 1
        elif name == 'playback.emby_copy_target_warm':
            counts['target_warm_ready' if fields.get('outcome') == 'ready' else 'target_warm_other'] += 1
        elif name == 'playback.emby_copy_reopen_retry':
            counts['diag_copy_reopen_retry'] += 1
        elif name == 'playback.remote_hls_proxy_open':
            counts['proxy_opened'] += 1
    return counts


def diagnostics_since(path: Path, offset: int) -> list[dict]:
    if not path.exists():
        return []
    records = []
    with path.open('rb') as handle:
        handle.seek(offset if offset <= path.stat().st_size else 0)
        for raw in handle:
            try:
                records.append(json.loads(raw))
            except ValueError:
                continue
    return records


def probe_result(lines) -> tuple[str, str]:
    """Last probe verdict in the window; `pending` if the probe never reported."""
    verdict, detail = 'pending', ''
    for line in lines:
        match = PROBE_RESULT.search(line)
        if match:
            verdict, detail = match.group(1), match.group(2).strip()
    return verdict, detail


def classify_run(app: dict[str, int], server: dict[str, int], verdict: str,
                 diag: dict[str, int] | None = None) -> list[str]:
    """Findings worth a human look; an empty list means a clean run."""
    findings = []
    if verdict != 'pass':
        findings.append(f'probe_{verdict}')
    if app['render_pipeline_failure']:
        findings.append('render_pipeline_failure')
    diag = diag or {}
    if app['copy_reopen_retry'] or diag.get('diag_copy_reopen_retry'):
        findings.append('copy_reopen_retry')
    if diag.get('prewarm_fetched_media_as_master') or (diag.get('prewarm_ran') and app['copy_child_verified']):
        findings.append('prewarm_on_copy_child')
    if server['gap_restarts'] > RESTART_STORM_THRESHOLD:
        findings.append('server_restart_storm')
    if app['aq_resync']:
        findings.append('aq_resync')
    return findings


def run_failed(result: dict) -> bool:
    """A recovered retry or audio resync is reported, not failed. A missing verdict, a
    prewarm against a verified copy child or a server restart storm (#421) fails the run."""
    return result['verdict'] != 'pass' or bool(
        {'prewarm_on_copy_child', 'server_restart_storm'} & set(result['findings']))


def screen_locked() -> bool:
    out = subprocess.run(['ioreg', '-n', 'Root', '-d1', '-a'], capture_output=True).stdout
    return re.search(rb'CGSSessionScreenIsLocked</key>\s*<true/>', out) is not None


def kubectl(args, context):
    base = ['kubectl'] + (['--context', context] if context else [])
    return subprocess.run(base + args, capture_output=True, text=True, timeout=60)


def server_line_count(opts) -> int:
    out = kubectl(['-n', opts.namespace, 'exec', f'deploy/{opts.deployment}', '-c', opts.container,
                   '--', 'wc', '-l', SERVER_LOG], opts.kube_context)
    if out.returncode != 0:
        raise SystemExit(f'cannot read Emby server log: {out.stderr.strip()[:200]}')
    return int(out.stdout.split()[0])


def server_lines_since(opts, start_line: int) -> list[str]:
    out = kubectl(['-n', opts.namespace, 'exec', f'deploy/{opts.deployment}', '-c', opts.container,
                   '--', 'tail', '-n', f'+{start_line + 1}', SERVER_LOG], opts.kube_context)
    return out.stdout.splitlines() if out.returncode == 0 else []


def app_lines_since(start: str) -> list[str]:
    out = subprocess.run(['/usr/bin/log', 'show', '--info', '--debug', '--style', 'compact',
                          '--start', start, '--predicate', 'process == "Labstream"'],
                         capture_output=True, text=True, timeout=180)
    return out.stdout.splitlines()


def stop_app(app: Path):
    subprocess.run(['pkill', '-f', str(app / 'Contents/MacOS/Labstream')], capture_output=True)
    time.sleep(2)


def run_once(opts, index: int, seek_ms: int, out_dir: Path) -> dict:
    stop_app(opts.app)
    start_line = server_line_count(opts)
    diagnostics = Path(str(DIAGNOSTICS).format(identity=opts.identity))
    diag_offset = diagnostics.stat().st_size if diagnostics.exists() else 0
    start = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    subprocess.run(['open', '-n', str(opts.app), '--args', '--vp-probe-backend', 'emby',
                    '--vp-probe-emby-playback', '--vp-probe-allow-live', '--vp-probe-scenario', 'seek',
                    '--vp-probe-query', opts.query, '--vp-probe-bitrate-kbps', '0',
                    '--vp-probe-seek-ms', str(seek_ms)], check=True)
    deadline = time.monotonic() + opts.timeout
    verdict, detail, lines = 'pending', '', []
    while time.monotonic() < deadline:
        time.sleep(10)
        lines = app_lines_since(start)
        verdict, detail = probe_result(lines)
        if verdict != 'pending':
            break
    time.sleep(opts.settle)
    lines = app_lines_since(start)
    verdict, detail = probe_result(lines)
    stop_app(opts.app)
    server = server_lines_since(opts, start_line)
    app_counts = count_signals(lines, APP_SIGNALS)
    server_counts = count_signals(server, SERVER_SIGNALS)
    pids = {int(m.group(1)) for m in (re.search(r'Labstream\[(\d+):', l) for l in lines) if m}
    diag_counts = count_diagnostics(diagnostics_since(diagnostics, diag_offset), pids)
    keep = re.compile('|'.join(p.pattern for p in (*APP_SIGNALS.values(), PROBE_RESULT)))
    (out_dir / f'run-{index:02d}-app.log').write_text('\n'.join(redact(l) for l in lines if keep.search(l)) + '\n')
    (out_dir / f'run-{index:02d}-server.log').write_text('\n'.join(redact(l) for l in server) + '\n')
    return dict(run=index, seek_ms=seek_ms, verdict=verdict, detail=redact(detail)[:160],
                app=app_counts, server=server_counts, diagnostics=diag_counts,
                findings=classify_run(app_counts, server_counts, verdict, diag_counts))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description='Repeat the Emby deep-seek reopen probe and correlate Emby server logs.')
    parser.add_argument('--query', required=True, help='exact private title; never written to the summary')
    parser.add_argument('--runs', type=int, default=20)
    parser.add_argument('--seek-ms', type=int, action='append', help='repeatable; cycles across runs')
    parser.add_argument('--app', type=Path, default=DEFAULT_APP)
    parser.add_argument('--timeout', type=int, default=180, help='seconds to wait for a probe verdict')
    parser.add_argument('--settle', type=int, default=3)
    parser.add_argument('--identity', default='downloads-overhaul', help='dev bundle id suffix of the staged app')
    parser.add_argument('--kube-context')
    parser.add_argument('--namespace', default='media')
    parser.add_argument('--deployment', default='emby')
    parser.add_argument('--container', default='emby')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/emby-reopen-soak')
    opts = parser.parse_args(argv)
    if not (opts.app / 'Contents/MacOS/Labstream').exists():
        raise SystemExit(f'no staged app at {opts.app}; run scripts/deploy-macos-to-host.sh first')
    if screen_locked():
        raise SystemExit('the Mac screen is locked; the app cannot open its window or render playback')
    seeks = opts.seek_ms or list(DEFAULT_SEEKS_MS)
    out_dir = opts.output / datetime.now().strftime('%Y%m%dT%H%M%S')
    out_dir.mkdir(parents=True, exist_ok=True)
    results = []
    try:
        for index in range(opts.runs):
            result = run_once(opts, index + 1, seeks[index % len(seeks)], out_dir)
            results.append(result)
            print(f"run {result['run']:02d} seek={result['seek_ms'] // 1000}s {result['verdict']} "
                  f"findings={','.join(result['findings']) or 'none'}", flush=True)
    finally:
        stop_app(opts.app)
        totals = {k: sum(r['app'][k] for r in results) for k in APP_SIGNALS}
        totals.update({k: sum(r['server'][k] for r in results) for k in SERVER_SIGNALS})
        for result in results:
            for key, value in result['diagnostics'].items():
                totals[key] = totals.get(key, 0) + value
        summary = dict(runs=len(results), passed=sum(r['verdict'] == 'pass' for r in results),
                       totals=totals, results=results)
        (out_dir / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
        print(json.dumps(dict(runs=summary['runs'], passed=summary['passed'], totals=totals), indent=2))
        print(f'evidence: {out_dir}')
    return 0 if results and not any(run_failed(r) for r in results) else 1


if __name__ == '__main__':
    sys.exit(main())
