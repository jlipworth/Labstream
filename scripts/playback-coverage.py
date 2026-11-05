#!/usr/bin/env python3
"""Map private inventory to synthetic test families without asserting library playback."""
import argparse
import ast
from collections import Counter, defaultdict
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
VIDEO_FIELDS = ('codec_name', 'profile', 'pix_fmt', 'bits_per_raw_sample', 'width', 'height',
                'r_frame_rate', 'avg_frame_rate', 'color_space', 'color_transfer', 'color_primaries', 'field_order')
AUDIO_FIELDS = ('codec_name', 'profile', 'bits_per_raw_sample', 'sample_rate', 'channels', 'channel_layout')
SIDE_FIELDS = ('side_data_type', 'dv_profile', 'dv_level', 'dv_bl_signal_compatibility_id')
ENCODERS = {'libx264': 'h264', 'libx265': 'hevc', 'libaom-av1': 'av1',
            'mpeg2video': 'mpeg2video', 'mjpeg': 'mjpeg', 'libmp3lame': 'mp3',
            'libopus': 'opus', 'dca': 'dts'}
MATRIX_STATUSES = {'signal-pass', 'signal-mismatch', 'fixture-invalid', 'generation-failed',
                   'playback-not-ready', 'capture-timeout', 'capture-inconclusive'}
MULTICHANNEL_STATUSES = {'routing-pass', 'routing-mismatch', 'fixture-invalid', 'generation-failed',
                        'layout-unverified', 'capture-failed', 'inconclusive'}
TECHNICAL_ENUMS = {
    'codec_name': set('h264 hevc av1 vp8 vp9 mpeg1video mpeg2video mpeg4 msmpeg4v2 msmpeg4v3 '
                      'mjpeg mjpegb vc1 wmv1 wmv2 wmv3 prores rawvideo h263 theora ffv1 png '
                      'aac ac3 eac3 dts truehd mlp flac alac opus vorbis mp1 mp2 mp3 '
                      'pcm_s8 pcm_u8 pcm_s16le pcm_s16be pcm_s24le pcm_s24be pcm_s32le pcm_s32be '
                      'pcm_f32le pcm_f32be pcm_f64le pcm_f64be pcm_bluray pcm_dvd wmalossless '
                      'wmav1 wmav2 wmapro adpcm_ima_wav'.split()),
    'container': {'matroska,webm', 'matroska', 'webm', 'mov,mp4,m4a,3gp,3g2,mj2',
                  'mov', 'mp4', 'm4a', 'avi', 'mpeg', 'mpegts', 'mpegtsraw', 'mxf', 'asf',
                  'hls', 'flv', 'ogg', 'wav', 'aiff', 'flac', 'aac', 'ac3', 'eac3', 'dts',
                  'truehd', 'mp3', 'image2', 'image2pipe', 'h264', 'hevc'},
    'profile': {'Baseline', 'Constrained Baseline', 'Main', 'Extended', 'High', 'High 10',
                'High 10 Intra', 'High 4:2:2', 'High 4:2:2 Intra', 'High 4:4:4',
                'High 4:4:4 Predictive', 'High 4:4:4 Intra', 'CAVLC 4:4:4', 'Multiview High',
                'Stereo High', 'Main 10', 'Main Still Picture', 'Rext', 'Simple', 'Advanced',
                'Advanced Simple Profile', 'Simple Profile', 'Main Profile', 'Main 4:2:2 10',
                'Main 4:4:4 10', 'Professional', 'Progressive', 'Lossless', 'Profile 0',
                'Profile 1', 'Profile 2', 'Profile 3', 'LC', 'HE-AAC', 'HE-AACv2', 'LD', 'ELD',
                'SSR', 'LTP', 'DTS', 'DTS-ES', 'DTS 96/24', 'DTS-HD HRA', 'DTS-HD MA',
                'DTS-HD MA + DTS:X', 'Dolby Digital Plus + Dolby Atmos', 'Dolby TrueHD + Dolby Atmos'},
    'color_primaries': set('bt709 bt470m bt470bg smpte170m smpte240m film bt2020 smpte428 '
                           'smpte431 smpte432 jedec-p22 reserved'.split()),
    'color_transfer': set('bt709 gamma22 gamma28 smpte170m smpte240m linear log log_sqrt '
                          'iec61966-2-4 bt1361e iec61966-2-1 bt2020-10 bt2020-12 smpte2084 '
                          'smpte428 arib-std-b67 bt470m bt470bg reserved'.split()),
    'color_space': set('rgb gbr bt709 fcc bt470bg smpte170m smpte240m ycgco bt2020nc '
                       'bt2020c smpte2085 chroma-derived-nc chroma-derived-c ictcp reserved'.split()),
    'field_order': set('progressive tt bb tb bt'.split()),
    'side_data_type': {'Audio Service Type', 'CPB properties', 'Content light level metadata',
                       'DOVI configuration record', 'Frame Cropping', 'Mastering display metadata',
                       'Display Matrix', 'Stereo 3D', 'Spherical Mapping', 'Skip Samples',
                       'HDR Dynamic Metadata SMPTE2094-40 (HDR10+)', 'HDR Dynamic Metadata CUVA 005.1 2021 (Vivid)'},
}
LAYOUTS = {'mono', 'stereo', 'downmix', '2.1', '3.0', '3.0(back)', '3.1', '4.0', 'quad',
           'quad(side)', '4.1', '5.0', '5.0(side)', '5.1', '5.1(side)', '6.0', '6.0(front)',
           'hexagonal', '6.1', '6.1(back)', '6.1(front)', '7.0', '7.0(front)', '7.1',
           '7.1(wide)', '7.1(wide-side)', 'octagonal', 'hexadecagonal', '22.2',
           '5.1.2', '5.1.4', '7.1.2', '7.1.4', '9.1.4', '9.1.6'}
SPEAKERS = set('FL FR FC LFE BL BR FLC FRC BC SL SR TC TFL TFC TFR TBL TBC TBR DL DR '
               'WL WR SDL SDR LFE2 TSL TSR BFC BFL BFR'.split())
NUMERIC_BOUNDS = dict(width=65536, height=65536, bits_per_raw_sample=128, sample_rate=768000,
                      channels=64, dv_profile=255, dv_level=255, dv_bl_signal_compatibility_id=255)


class InvalidCoverage(ValueError):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True)


def fingerprint(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def safe_value(field, value):
    """Only recognized technical enums or bounded typed values cross the privacy boundary."""
    if field in NUMERIC_BOUNDS:
        if type(value) is int and 0 <= value <= NUMERIC_BOUNDS[field]: return value
        if isinstance(value, str) and re.fullmatch(r'\d{1,6}', value) and int(value) <= NUMERIC_BOUNDS[field]: return value
    elif field in ('r_frame_rate', 'avg_frame_rate'):
        if (isinstance(value, str) and re.fullmatch(r'\d{1,10}/\d{1,10}', value) and
                all(int(part) <= 2**31-1 for part in value.split('/'))): return value
    elif field == 'pix_fmt' and isinstance(value, str):
        if (value in {'rgb24', 'bgr24', 'rgba', 'bgra', 'argb', 'abgr', 'gray', 'gray8', 'pal8',
                      'nv12', 'nv21', 'uyvy422', 'yuyv422', 'monow', 'monob'} or
                re.fullmatch(r'(?:yuvj?(?:410|411|420|422|440|444)p|yuva(?:420|422|444)p|gbrp|gbrap|gray)(?:(?:9|10|12|14|16)(?:le|be))?', value)):
            return value
    elif field == 'channel_layout' and isinstance(value, str):
        if value in LAYOUTS: return value
        match = re.fullmatch(r'(\d{1,2}) channels \(([A-Z0-9+]+)\)', value)
        if match and 1 <= int(match[1]) <= 64:
            speakers = match[2].split('+')
            if len(speakers) == int(match[1]) and len(set(speakers)) == len(speakers) and set(speakers) <= SPEAKERS:
                return value
    elif field == 'generated_at' and isinstance(value, str):
        if re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})', value):
            try: datetime.fromisoformat(value); return value
            except ValueError: pass
    elif isinstance(value, str) and value in TECHNICAL_ENUMS.get(field, set()): return value
    return 'unknown'


def profiles_from_source(path):
    for node in ast.parse(path.read_text()).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'PROFILES' for t in node.targets):
            return ast.literal_eval(node.value)
    raise InvalidCoverage('fixture profile catalog unavailable')


def catalog():
    result = {}
    for name, video, audio, container, pixel in profiles_from_source(ROOT/'scripts/playback-signal-matrix.py'):
        result['matrix:'+name] = dict(id='matrix:'+name, suite='matrix', name=name,
            video=ENCODERS.get(video, video), audio=ENCODERS.get(audio, audio), sourceChannels=2,
            packaging='hls-'+container, pixelFormat=pixel, width=160, height=90, framesPerSecond=30)
    for name, audio, container in profiles_from_source(ROOT/'scripts/playback-multichannel-lab.py'):
        result['multichannel:'+name] = dict(id='multichannel:'+name, suite='multichannel', name=name,
            video='h264', audio=ENCODERS.get(audio, audio), sourceChannels=6,
            packaging='hls-'+container, pixelFormat='yuv420p', width=160, height=90, framesPerSecond=30)
    return result


def inventory_groups(data):
    if not isinstance(data, dict) or type(data.get('schema_version')) is not int or data.get('schema_version') != 1 or not isinstance(data.get('items'), list):
        raise InvalidCoverage('unsupported inventory schema')
    if type(data.get('discovered_video_files')) is not int or data['discovered_video_files'] < len(data['items']):
        raise InvalidCoverage('invalid inventory denominator')
    seen = set()
    groups = {}
    stats = Counter()
    counts = {name: Counter() for name in ('videoCodecFiles', 'audioCodecFiles', 'audioLayoutFiles',
                                          'videoCodecTracks', 'audioCodecTracks')}
    for row in data['items']:
        if not isinstance(row, dict) or not isinstance(row.get('id'), str) or not row['id'] or row['id'] in seen:
            raise InvalidCoverage('missing or duplicate inventory identity')
        seen.add(row['id'])
        if row.get('error'):
            stats['probeErrors'] += 1
            continue
        facts = row.get('facts')
        if not isinstance(facts, dict) or not isinstance(facts.get('streams'), list) or not facts['streams']:
            raise InvalidCoverage('successful inventory row lacks streams')
        videos, audios = [], []
        for stream in facts['streams']:
            if not isinstance(stream, dict): raise InvalidCoverage('invalid stream metadata')
            kind = stream.get('codec_type')
            if kind not in ('video', 'audio'): continue
            disposition = stream.get('disposition', {})
            if not isinstance(disposition, dict): raise InvalidCoverage('invalid stream disposition')
            if kind == 'video' and disposition.get('attached_pic'): continue
            fields = VIDEO_FIELDS if kind == 'video' else AUDIO_FIELDS
            item = {key: safe_value(key, stream.get(key)) for key in fields}
            if kind == 'video':
                side_data = stream.get('side_data', [])
                if not isinstance(side_data, list) or any(not isinstance(s, dict) for s in side_data):
                    raise InvalidCoverage('invalid video side data')
                item['side_data'] = sorted([{key: safe_value(key, side[key]) for key in SIDE_FIELDS if key in side}
                                            for side in side_data], key=canonical)
                videos.append(item)
                counts['videoCodecTracks'][item['codec_name']] += 1
            else:
                audios.append(item)
                counts['audioCodecTracks'][item['codec_name']] += 1
        stats['successfulProbes'] += 1
        counts['videoCodecFiles'].update({v['codec_name'] for v in videos})
        counts['audioCodecFiles'].update({a['codec_name'] for a in audios})
        counts['audioLayoutFiles'].update({f"{a['codec_name']} | {a['channels']} channels | {a['channel_layout']}" for a in audios})
        if not videos:
            stats['withoutPlayableVideo'] += 1
            continue
        stats['eligibleVideoFiles'] += 1
        if not audios: stats['withoutAudio'] += 1
        technical = dict(container=safe_value('container', facts.get('container')),
                         video=sorted(videos, key=canonical), audio=sorted(audios, key=canonical))
        key = fingerprint(technical)
        group = groups.setdefault(key, dict(combinationID=key, files=0, dimensions=technical))
        group['files'] += 1
    return groups, stats, counts


def result_outcomes(documents, profiles):
    """Supplied reports describe historical synthetic experiments, never fresh acceptance."""
    outcomes = defaultdict(set)
    for data in documents:
        if isinstance(data, dict):
            if (type(data.get('schema')) is not int or data.get('schema') != 1 or data.get('status') != 'complete' or
                    not isinstance(data.get('runID'), str) or not data['runID']):
                raise InvalidCoverage('incomplete or unsupported matrix report')
            rows, suite = data.get('results'), 'matrix'
        elif isinstance(data, list): rows, suite = data, 'multichannel'
        else: raise InvalidCoverage('unsupported synthetic report')
        if not isinstance(rows, list) or not rows: raise InvalidCoverage('synthetic report has no results')
        seen = set()
        for row in rows:
            if not isinstance(row, dict): raise InvalidCoverage('invalid synthetic result row')
            name = row.get('name') if suite == 'matrix' else row.get('profile', row.get('name'))
            if not isinstance(name, str): raise InvalidCoverage('missing synthetic profile')
            key = suite+':'+name
            if key not in profiles: raise InvalidCoverage('unknown synthetic profile')
            status = row.get('status')
            allowed = MATRIX_STATUSES if suite == 'matrix' else MULTICHANNEL_STATUSES
            if not isinstance(status, str) or status not in allowed: raise InvalidCoverage('unknown synthetic outcome')
            requested = row.get('requestedChannels')
            if requested is not None and (type(requested) is not int or requested not in (2, 6)):
                raise InvalidCoverage('invalid requested output channel count')
            identity = (key, row.get('requestedChannels'))
            if identity in seen: raise InvalidCoverage('duplicate synthetic result')
            seen.add(identity)
            if status in ('signal-pass', 'routing-pass'):
                if row.get('failures') != [] or not isinstance(row.get('runID'), str) or not row['runID']:
                    raise InvalidCoverage('contradictory or unbound synthetic pass')
                if suite == 'matrix':
                    fixture = row.get('fixture')
                    if not isinstance(fixture, dict) or fixture.get('name') != name or fixture.get('status') != 'generated':
                        raise InvalidCoverage('synthetic pass lacks fixture binding')
                elif (row.get('requestedChannels') not in (2, 6) or
                      not isinstance(row.get('offlineReference'), dict) or row['offlineReference'].get('failures') != []):
                    raise InvalidCoverage('routing pass lacks reference validation')
                if suite == 'multichannel' and row['requestedChannels'] == 6:
                    tags = row.get('observedChannelLayoutTags')
                    if (not isinstance(tags, list) or not tags or
                            any(type(tag) is not int or not 0 < tag < 2**32 for tag in tags)):
                        raise InvalidCoverage('six-channel routing pass lacks observed layout metadata')
            suffix = '' if suite == 'matrix' else f":output-{row.get('requestedChannels', 'unavailable')}ch"
            outcomes[key].add(status+suffix)
    return {key: sorted(values) for key, values in sorted(outcomes.items())}


def build_report(inventory, results=(), limit=20, provenance=None):
    if type(limit) is not int or not 1 <= limit <= 100: raise InvalidCoverage('limit must be between 1 and 100')
    groups, stats, counts = inventory_groups(inventory)
    profiles = catalog()
    outcomes = result_outcomes(results, profiles)
    weighted = Counter()
    covered = set()
    all_facets = set()
    for group in groups.values():
        dims = group['dimensions']
        pairs = {(v['codec_name'], a['codec_name']) for v in dims['video'] for a in dims['audio']}
        candidates = sorted(key for key, profile in profiles.items() if (profile['video'], profile['audio']) in pairs)
        channel_candidates = sorted(key for key in candidates if any(
            a['codec_name'] == profiles[key]['audio'] and a['channels'] == profiles[key]['sourceChannels'] for a in dims['audio']))
        attempted = [key for key in candidates if key in outcomes]
        passes = [key for key in candidates if any(s.startswith(('signal-pass', 'routing-pass')) for s in outcomes.get(key, []))]
        group.update(syntheticFamilyProfiles=candidates, syntheticFamilyAndChannelCountProfiles=channel_candidates,
                     suppliedEvidenceProfiles=attempted, suppliedPassProfiles=passes,
                     exactSyntheticMatch='not-established', libraryPlayback='not-tested')
        for name, value in [('withFamilyFixture', candidates), ('withFamilyAndChannelCountFixture', channel_candidates),
                            ('withSuppliedFamilyResult', attempted), ('withSuppliedFamilyPass', passes)]:
            if value: weighted[name] += group['files']
        # The plan covers distinct codec/layout families first, then high-file-count combinations.
        facets = {('container', dims['container'])}
        facets.update(('video', canonical(v)) for v in dims['video'])
        facets.update(('audio', canonical(a)) for a in dims['audio'])
        group['_facets'] = facets
        all_facets.update(facets)
    chosen = []
    remaining = list(groups.values())
    while remaining and len(chosen) < limit:
        # Uncovered facets, weighted by represented files; deterministic ID tie-break.
        best = min(remaining, key=lambda g: (-len(g['_facets']-covered)*g['files'], -g['files'], g['combinationID']))
        covered.update(best['_facets'])
        chosen.append({key: value for key, value in best.items() if key != '_facets'})
        remaining.remove(best)
    successful = stats['successfulProbes']
    eligible = stats['eligibleVideoFiles']
    report = dict(schemaVersion=1, scope='synthetic-family-coverage-not-library-playback',
        status='reported', inventoryGeneratedAt=safe_value('generated_at', inventory.get('generated_at')),
        provenance=provenance or {},
        inventory=dict(discoveredFiles=inventory['discovered_video_files'], listedFiles=len(inventory['items']),
            successfulProbes=successful, probeErrors=stats['probeErrors'], eligibleVideoFiles=eligible,
            successfulWithoutPlayableVideo=stats['withoutPlayableVideo'], eligibleWithoutAudio=stats['withoutAudio'],
            unlistedFiles=inventory['discovered_video_files']-len(inventory['items']),
            completeFileInventory=inventory.get('complete_file_inventory') is True and len(inventory['items']) == inventory['discovered_video_files'],
            completeProbeCoverage=inventory.get('complete_probe_coverage') is True and stats['probeErrors'] == 0 and len(inventory['items']) == inventory['discovered_video_files'],
            technicalCombinations=len(groups)),
        counts={key: dict(sorted(value.items())) for key, value in counts.items()},
        syntheticFamilyCoverage={key: dict(files=weighted[key], denominator=eligible,
            percent=round(100*weighted[key]/eligible, 2) if eligible else None) for key in
            ('withFamilyFixture', 'withFamilyAndChannelCountFixture', 'withSuppliedFamilyResult', 'withSuppliedFamilyPass')},
        exactLibraryValidation=dict(status='not-measured', testedFiles=0, passedFiles=0,
            reason='Synthetic family matches are not exact library-source, delivery-route, or playback evidence.'),
        fixtureCatalog=[dict(profile, suppliedOutcomes=outcomes.get(key, [])) for key, profile in sorted(profiles.items())],
        priorityPlan=dict(limit=limit, selectedCombinations=len(chosen), representedFiles=sum(g['files'] for g in chosen),
            denominator=eligible, selectedTechnicalFacets=len(covered), totalTechnicalFacets=len(all_facets),
            selection='greedy new technical facets times file count; then file count; then combination ID'),
        priorityCombinations=chosen,
        limitations=['Counts by codec/layout overlap when files have multiple tracks; each bucket counts a file once.',
            'Family matches ignore packaging, resolution, profile, HDR and other exact-source dimensions.',
            'Channel-count matches do not verify channel layout or speaker routing.',
            'Supplied synthetic outcomes are historical inputs, not fresh verification of this checkout.',
            'No library media was read, decoded, selected by title, or played by this report.',
            'Technical combinations exclude subtitles, language, disposition and title-specific mastering values; they differ from full inventory combinations.'])
    return report


def markdown(report):
    inv = report['inventory']
    lines = ['# Headless codec coverage', '',
        '**Synthetic family coverage only. No library file receives a playback pass from this report.**', '',
        f"Inventory: {inv['successfulProbes']} successful probes / {inv['discoveredFiles']} discovered files; {inv['probeErrors']} probe errors.",
        f"Eligible video files: {inv['eligibleVideoFiles']}; technical combinations: {inv['technicalCombinations']}.", '',
        '| Family-level relationship | Files | Eligible files | Percent |', '| --- | ---: | ---: | ---: |']
    for key, value in report['syntheticFamilyCoverage'].items():
        lines.append(f"| {key} | {value['files']} | {value['denominator']} | {value['percent']} |")
    lines += ['', 'These overlapping relationships describe candidate tests and supplied synthetic evidence. Exact library playback remains unmeasured.', '',
              '| Priority combination | Files | Video | Audio | Candidate profiles |', '| --- | ---: | --- | --- | --- |']
    for row in report['priorityCombinations']:
        video = ', '.join(sorted({v['codec_name'] for v in row['dimensions']['video']}))
        audio = ', '.join(sorted({a['codec_name'] for a in row['dimensions']['audio']})) or 'none'
        lines.append(f"| {row['combinationID'][:16]} | {row['files']} | {video} | {audio} | {', '.join(row['syntheticFamilyProfiles']) or 'none'} |")
    lines += ['', *['- '+item for item in report['limitations']], '']
    return '\n'.join(lines)


def read_json(path):
    try:
        raw = path.read_bytes()
        return json.loads(raw), hashlib.sha256(raw).hexdigest()
    except (OSError, ValueError) as error:
        # Never expose input filenames or parser excerpts from private inventory.
        raise InvalidCoverage('input unavailable or invalid JSON') from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--results', type=Path, action='append', default=[])
    parser.add_argument('--output', type=Path, default=ROOT/'build/playback-coverage')
    parser.add_argument('--limit', type=int, default=20)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        output = args.output.resolve()
        if not output.is_relative_to(ROOT/'build'): raise InvalidCoverage('output must be under build/')
        if subprocess.run(['git', 'check-ignore', '-q', str(output/'coverage.json')], cwd=ROOT).returncode:
            raise InvalidCoverage('output must be gitignored')
        if subprocess.run(['git', 'ls-files', '--', str(output)], cwd=ROOT, capture_output=True, check=True).stdout:
            raise InvalidCoverage('output must not contain tracked files')
        inventory, inventory_hash = read_json(args.inventory)
        supplied = [read_json(path) for path in args.results]
        report = build_report(inventory, [data for data, _ in supplied], args.limit,
                              dict(inventorySHA256=inventory_hash, resultSHA256=[digest for _, digest in supplied]))
        output.mkdir(parents=True, exist_ok=True)
        (output/'coverage.json').write_text(json.dumps(report, indent=2)+'\n')
        (output/'coverage.md').write_text(markdown(report))
        print(json.dumps(dict(status=report['status'], scope=report['scope'], inventory=report['inventory'],
                              syntheticFamilyCoverage=report['syntheticFamilyCoverage'], priorityPlan=report['priorityPlan']), indent=2))
    except InvalidCoverage as error:
        parser.exit(2, f'coverage: {error}\n')


if __name__ == '__main__': main()
