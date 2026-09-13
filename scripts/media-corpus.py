#!/usr/bin/env python3
"""Private, resumable metadata corpus; never copies or encodes media."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import subprocess
from collections import Counter

VIDEO_EXTENSIONS = {'.mkv', '.mp4', '.m4v', '.mov', '.avi', '.ts', '.m2ts', '.webm', '.mpg', '.mpeg', '.wmv', '.vob'}
SCHEMA = 1


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def normalize(raw):
    """Retain all streams, including unknown fields and codec side data."""
    streams = []
    keys = ('codec_type', 'codec_name', 'profile', 'codec_tag_string', 'pix_fmt',
            'bits_per_raw_sample', 'width', 'height', 'r_frame_rate', 'avg_frame_rate',
            'color_space', 'color_transfer', 'color_primaries', 'field_order',
            'sample_rate', 'channels', 'channel_layout')
    for source in raw.get('streams', []):
        stream = {key: source.get(key, 'unknown') for key in keys}
        stream['disposition'] = source.get('disposition', {})
        stream['side_data'] = source.get('side_data_list', [])
        streams.append(stream)
    return {'container': raw.get('format', {}).get('format_name', 'unknown'), 'streams': streams}


def combination(facts):
    # Stream side data may contain per-title mastering values; retain raw values
    # in inventory but group coverage by type and Dolby Vision profile.
    result = json.loads(json.dumps(facts))
    for stream in result['streams']:
        stream['side_data'] = [{k: d[k] for k in ('side_data_type', 'dv_profile', 'dv_level', 'dv_bl_signal_compatibility_id') if k in d} for d in stream['side_data']]
    return result


def summarize(records):
    groups = {}
    for row in records:
        if row.get('error'):
            continue
        facts = combination(row['facts'])
        key = digest(facts)
        group = groups.setdefault(key, {'combination_id': key, 'facts': facts, 'count': 0, 'representative': row})
        group['count'] += 1
        if (row['size'], row['id']) < (group['representative']['size'], group['representative']['id']):
            group['representative'] = row
    return sorted(groups.values(), key=lambda g: g['combination_id'])


def stratified(rows, roots):
    """Deterministically interleave source roots; keep every candidate."""
    buckets = [[] for _ in roots] + [[]]
    for row in sorted(rows, key=lambda r: r['path']):
        index = next((i for i, root in enumerate(roots) if row['path'].startswith(root.rstrip('/') + '/')), len(roots))
        buckets[index].append(row)
    return [bucket[i] for i in range(max(map(len, buckets), default=0)) for bucket in buckets if i < len(bucket)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('build/media-corpus'))
    parser.add_argument('--context', required=True)
    parser.add_argument('--namespace', default='media')
    parser.add_argument('--target', default='deploy/jellyfin')
    parser.add_argument('--container', default='jellyfin')
    parser.add_argument('--root', action='append', required=True)
    parser.add_argument('--ffprobe', default='/usr/lib/jellyfin-ffmpeg/ffprobe')
    parser.add_argument('--workers', type=int, choices=(1, 2), default=2)
    parser.add_argument('--timeout', type=int, default=30)
    parser.add_argument('--summarize-only', action='store_true', help='Export currently cached rows without probing missing files')
    parser.add_argument('--limit', type=int, help='Bound initial exploratory run; omit for all media')
    args = parser.parse_args()
    os.umask(0o077)
    if args.timeout < 1 or (args.limit is not None and args.limit < 1):
        parser.error('timeout and limit must be positive')
    args.output.mkdir(parents=True, exist_ok=True)
    ignored = subprocess.run(['git', 'check-ignore', '-q', str(args.output / 'inventory.json')])
    tracked = subprocess.run(['git', 'ls-files', '--', str(args.output)], capture_output=True, check=True).stdout
    if ignored.returncode or tracked:
        parser.error('output must be gitignored; refusing to write private inventory')
    base = ['kubectl', '--context', args.context, '-n', args.namespace, 'exec', args.target, '-c', args.container, '--']
    listing = subprocess.run(base + ['find', *args.root, '-type', 'f', '-printf', r'%p\0%s\0%T@\0'], capture_output=True, check=True, timeout=300).stdout
    (args.output / 'files.nul').write_bytes(listing)
    fields = listing.split(b'\0')
    rows = []
    for index in range(0, len(fields) - 1, 3):
        path, size, mtime = (x.decode('utf-8', errors='surrogateescape') for x in fields[index:index+3])
        if Path(path).suffix.lower() not in VIDEO_EXTENSIONS:
            continue
        row = {'path': path, 'size': int(size), 'mtime': mtime}
        row['id'] = digest([SCHEMA, args.context, args.namespace, args.target, args.container, args.ffprobe, 10000000, 10000000, row])
        rows.append(row)
    rows = stratified(rows, args.root)
    total = len(rows)
    scheduled_ids = {r['id'] for r in (rows[:args.limit] if args.limit else rows)}
    cache = args.output / 'cache'
    cache.mkdir(exist_ok=True)
    def probe(row):
        file = cache / (row['id'] + '.json')
        if file.exists():
            result = json.loads(file.read_text())
            if result.get('error') and (args.summarize_only or row['id'] not in scheduled_ids):
                return result
            if not result.get('error'):
                result['facts'] = normalize(result['raw'])
                return result
        result = dict(row)
        if args.summarize_only or row['id'] not in scheduled_ids:
            return {**result, 'error': 'not_yet_probed'}
        try:
            proc = subprocess.run(base + ['timeout', str(args.timeout), args.ffprobe, '-v', 'error', '-probesize', '10000000', '-analyzeduration', '10000000', '-show_streams', '-show_format', '-of', 'json', row['path']], capture_output=True, timeout=args.timeout + 15)
            if proc.returncode:
                result['error'] = 'probe_exit_' + str(proc.returncode)
            else:
                result['raw'] = json.loads(proc.stdout)
                result['facts'] = normalize(result['raw'])
                if not result['raw'].get('streams'):
                    result['error'] = 'no_streams'
        except (subprocess.TimeoutExpired, ValueError, OSError) as error:
            result['error'] = type(error).__name__
        temporary = file.with_suffix('.tmp')
        temporary.write_text(json.dumps(result, indent=2))
        temporary.replace(file)
        return result
    records = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        for row in pool.map(probe, rows):
            records.append(row)
            if len(records) % 100 == 0:
                print(f'Probed/cached {len(records)}/{len(rows)}', flush=True)
    provenance = {'generated_at': datetime.now(timezone.utc).isoformat(), 'schema_version': SCHEMA, 'source': {'context': args.context, 'namespace': args.namespace, 'target': args.target, 'container': args.container, 'roots': args.root, 'ffprobe': args.ffprobe, 'probe_options': {'probesize': 10000000, 'analyzeduration': 10000000}, 'cache_identity_version': 1}, 'discovered_video_files': total, 'listed': len(records), 'processed': sum(r.get('error') != 'not_yet_probed' for r in records), 'complete_file_inventory': True, 'complete_probe_coverage': len(records) == total and not any(r.get('error') for r in records)}
    (args.output / 'inventory.json').write_text(json.dumps({**provenance, 'items': records}, indent=2))
    groups = summarize(records)
    (args.output / 'representatives.json').write_text(json.dumps({**provenance, 'combinations': groups}, indent=2))
    summary = {**{k: v for k, v in provenance.items() if k != 'source'}, 'successful': sum(not r.get('error') for r in records), 'errors': dict(Counter(r['error'] for r in records if r.get('error'))), 'combinations': len(groups), 'video_codecs': dict(Counter(s['codec_name'] for r in records for s in r.get('facts', {}).get('streams', []) if s['codec_type'] == 'video' and not s.get('disposition', {}).get('attached_pic')))}
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
