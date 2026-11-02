"""Verify and split one inventoried 96 kHz/24-bit DVD-Audio presentation.

Development utility for American Beauty/Fragile: one title set, one cell per
track, contiguous sectors, constant format, exact ATS durations. Reads a
completed decrypted title-set AOB, never a device. Refuses unknown layouts.
"""
import argparse
import hashlib
import json
import pathlib
import re
import shutil
import subprocess


def navigation(path, row, count):
    records = {kind: [] for kind in ('title', 'track', 'cell')}
    for line in path.read_text().splitlines():
        fields = line.split()
        if not fields or fields[0] not in records:
            continue
        record = dict(field.split('=', 1) for field in fields[1:])
        if int(record['ats']) != 1 or int(record.get('title_row', record.get('row'))) != row:
            continue
        records[fields[0]].append({k: int(v, 0) for k, v in record.items()})
    if len(records['title']) != 1:
        raise ValueError('expected exactly one matching title in ATS 1')
    title = records['title'][0]
    tracks, cells = records['track'], records['cell']
    if len(tracks) != title['tracks'] or len(cells) != len(tracks) or title['cells'] != len(cells):
        raise ValueError('expected one cell per track')
    if sum(t['duration_pts'] for t in tracks) != title['duration_pts']:
        raise ValueError('track durations do not sum to title duration')
    for i, (track, cell) in enumerate(zip(tracks, cells), 1):
        if track['number'] != i or track['first_cell'] != i or cell['row'] != i or cell['type'] != 0:
            raise ValueError('unsupported track/cell mapping')
        if cell['end'] < cell['start'] or (i > 1 and cell['start'] != cells[i-2]['end']+1):
            raise ValueError('noncontiguous/invalid cells')
    count = len(tracks) if count is None else count
    if not 1 <= count <= len(tracks):
        raise ValueError('invalid track count')
    return title, tracks[:count], cells[:count]


def first_audio_pts(source, cell):
    """Read MPEG PES timestamps at a cell start, not rounded probe durations."""
    with source.open('rb') as file:
        file.seek(cell['start']*2048)
        data = file.read(min(32, cell['end']-cell['start']+1)*2048)
    for offset in range(0, len(data), 2048):
        sector = data[offset:offset+2048]
        if len(sector) != 2048 or sector[:4] != b'\x00\x00\x01\xba':
            continue
        pos = 14+(sector[13] & 7)
        while pos+9 <= len(sector) and sector[pos:pos+3] == b'\x00\x00\x01':
            length = int.from_bytes(sector[pos+4:pos+6], 'big')
            end = pos+6+length
            if end > len(sector):
                raise ValueError('PES extends beyond sector in this constrained parser')
            if sector[pos+3] == 0xbd and sector[pos+7] & 0x80:
                if length < 8 or sector[pos+8] < 5:
                    raise ValueError('truncated PES timestamp')
                if sector[pos+6] & 0x30:
                    raise ValueError('scrambled audio packet at cell start')
                a = sector[pos+9:pos+14]
                if any(not (a[i] & 1) for i in (0, 2, 4)):
                    raise ValueError('invalid PTS marker bits')
                pts = ((a[0]>>1 & 7)<<30) | (a[1]<<22) | ((a[2]>>1)<<15) | (a[3]<<7) | (a[4]>>1)
                return dict(sector=cell['start']+offset//2048, pts=pts)
            pos = end
    raise ValueError('no audio PTS in first 32 cell sectors')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=pathlib.Path)
    parser.add_argument('inventory', type=pathlib.Path)
    parser.add_argument('output', type=pathlib.Path)
    parser.add_argument('--title-row', type=int, required=True)
    parser.add_argument('--track-count', type=int)
    parser.add_argument('--artist', required=True)
    parser.add_argument('--album', required=True)
    parser.add_argument('--presentation', choices=['surround', 'stereo'], required=True)
    parser.add_argument('--independent-cells', action='store_true', help='Also compare each fresh cell decode with its split track')
    parser.add_argument('--reset-decoder-per-cell', action='store_true', help='For self-contained, reset-per-track programs: decode each cell freshly before joining')
    args = parser.parse_args()
    ffmpeg, ffprobe = shutil.which('ffmpeg'), shutil.which('ffprobe')
    if not ffmpeg or not ffprobe:
        parser.error('ffmpeg and ffprobe are required')
    root = args.output.resolve()
    repo = pathlib.Path(__file__).resolve().parents[2]
    if root == repo or repo in root.parents:
        parser.error('media output must be outside the repository')
    title, nav, cells = navigation(args.inventory, args.title_row, args.track_count)
    if args.source.stat().st_size < (cells[-1]['end']+1)*2048:
        parser.error('source is incomplete for the selected presentation')
    channels = 6 if args.presentation == 'surround' else 2
    layout = '5.1' if channels == 6 else 'stereo'
    tracks, position = [], 0
    for track, cell in zip(nav, cells):
        packet = first_audio_pts(args.source, cell)
        if packet['pts'] != track['start_pts']:
            parser.error(f"track {track['number']}: first packet PTS disagrees with navigation")
        numerator = track['duration_pts']*96000
        if numerator % 90000:
            parser.error('navigation duration is not an integer frame count')
        end = position + numerator//90000
        tracks.append(dict(number=track['number'], start_frame=position, end_frame=end,
                           navigation=track, cell=cell, first_audio_packet=packet,
                           file=f"{track['number']:02d} - Track {track['number']:02d}.flac"))
        position = end
    timeline = [nav[0]['start_pts']]
    for track in nav[:-1]:
        timeline.append(timeline[-1]+track['duration_pts'])
    starts = [t['start_pts'] for t in nav]
    resets = len(nav) > 1 and starts == [starts[0]]*len(nav)
    if starts != timeline and not resets:
        parser.error('unsupported mixed timestamp discontinuities')
    if resets and not args.independent_cells:
        parser.error('reset-per-track navigation requires --independent-cells validation')
    if args.reset_decoder_per_cell and not resets:
        parser.error('per-cell reset mode requires reset-per-track navigation')
    root.mkdir(parents=True, exist_ok=False)
    common = [ffmpeg, '-hide_banner', '-v', 'warning', '-xerror', '-n']

    def clean(log):
        if log.stat().st_size:
            raise RuntimeError(f'review diagnostics: {log}')

    def run(command, log):
        with log.open('wb') as err:
            subprocess.run(command, stdout=subprocess.DEVNULL, stderr=err, check=True, timeout=1800)
        clean(log)

    def feed(command, first, last, log, expected_resets=False):
        with log.open('wb') as err:
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=err)
            try:
                with args.source.open('rb') as source:
                    source.seek(first*2048)
                    remaining = (last-first+1)*2048
                    digest = hashlib.sha256()
                    while remaining:
                        block = source.read(min(1024*1024, remaining))
                        if not block:
                            raise RuntimeError('short source read')
                        digest.update(block)
                        process.stdin.write(block)
                        remaining -= len(block)
                process.stdin.close()
                if process.wait(timeout=1800):
                    raise RuntimeError(f'decoder failed: {log}')
            except BaseException:
                process.kill()
                process.wait()
                raise
        if expected_resets:
            lines = log.read_text().splitlines()
            if len(lines) != len(nav)-1:
                raise RuntimeError(f'expected one timestamp reset per track transition: {log}')
            accumulated = 0
            for previous, line in zip(nav, lines):
                match = re.fullmatch(r'\[aist#0:0/mlp @ 0x[0-9a-f]+\] timestamp discontinuity \(stream id=161\): (-?\d+), new offset= *(-?\d+)', line)
                accumulated += previous['duration_pts']
                if (not match or abs(int(match[1])+previous['duration_pts']*1_000_000/90000) > 2
                        or abs(int(match[2])-accumulated*1_000_000/90000) > len(nav)):
                    raise RuntimeError(f'diagnostic does not match navigation reset: {line}')
        else:
            clean(log)
        return digest.hexdigest()

    def stream(path):
        data = json.loads(subprocess.check_output([ffprobe, '-v', 'error', '-show_streams', '-of', 'json', str(path)], timeout=60))
        if len(data['streams']) != 1:
            raise RuntimeError('expected one output stream')
        return data['streams'][0]

    def check(path, frames):
        info = stream(path)
        expected = dict(codec_name='flac', sample_rate='96000', channels=channels, channel_layout=layout,
                        bits_per_raw_sample='24', time_base='1/96000', duration_ts=frames)
        for key, value in expected.items():
            if info.get(key) != value:
                raise RuntimeError(f'{path.name}: expected {key}={value}, got {info.get(key)}')
        return info

    full = root/'Continuous.flac'
    print(f'{args.album} {args.presentation}: encoding {len(tracks)} tracks, expected {position} frames', flush=True)
    source_cell_hashes = []
    if args.reset_decoder_per_cell:
        (root/'cells').mkdir()
        for track in tracks:
            number, cell = track['number'], track['cell']
            cell_output = root/'cells'/f'{number:02d}.flac'
            print(f'Decoding cell {number} with fresh decoder state', flush=True)
            source_cell_hashes.append(feed(common + ['-f', 'mpeg', '-i', 'pipe:0', '-map', '0:a:0', '-af', 'asetpts=N/SR/TB',
                '-c:a', 'flac', '-sample_fmt', 's32', '-bits_per_raw_sample', '24', str(cell_output),
                '-map', '0:a:0', '-af', 'asetpts=N/SR/TB', '-c:a', 'pcm_s24le', '-f', 'hash', '-hash', 'sha256',
                str(root/f'cell-{number:02d}.sha256')], cell['start'], cell['end'], root/f'cell-{number:02d}.stderr'))
            check(cell_output, track['end_frame']-track['start_frame'])
        concat = root/'cells.ffconcat'
        concat.write_text('ffconcat version 1.0\n'+''.join(f"file 'cells/{t['number']:02d}.flac'\n" for t in tracks))
        run(common + ['-f', 'concat', '-safe', '1', '-i', str(concat), '-map', '0:a:0', '-af', 'asetpts=N/SR/TB',
            '-c:a', 'flac', '-sample_fmt', 's32', '-bits_per_raw_sample', '24', '-metadata', f'artist={args.artist}',
            '-metadata', f'album={args.album}', '-metadata', f'title={args.presentation} continuous program', str(full)], root/'encode.stderr')
        source_hash = None
    else:
        source_hash = feed(common + ['-f', 'mpeg', '-i', 'pipe:0', '-map', '0:a:0', '-af', 'asetpts=N/SR/TB',
            '-c:a', 'flac', '-sample_fmt', 's32', '-bits_per_raw_sample', '24', '-metadata', f'artist={args.artist}',
            '-metadata', f'album={args.album}', '-metadata', f'title={args.presentation} continuous program', str(full),
            '-map', '0:a:0', '-af', 'asetpts=N/SR/TB', '-c:a', 'pcm_s24le', '-f', 'hash', '-hash', 'sha256', str(root/'source-pcm.sha256')],
            cells[0]['start'], cells[-1]['end'], root/'encode.stderr', expected_resets=resets)
    info = check(full, position)
    print('Continuous frame count matches navigation; splitting at exact sample offsets', flush=True)
    filters = [f'[0:a]asplit={len(tracks)}'+''.join(f'[s{i}]' for i in range(len(tracks)))]
    for i, track in enumerate(tracks):
        filters.append(f"[s{i}]atrim=start_sample={track['start_frame']}:end_sample={track['end_frame']},asetpts=N/SR/TB[t{i}]")
    command = common + ['-i', str(full), '-filter_complex', ';'.join(filters)]
    for i, track in enumerate(tracks):
        command += ['-map', f'[t{i}]', '-c:a', 'flac', '-sample_fmt', 's32', '-bits_per_raw_sample', '24',
                    '-metadata', f'title=Track {i+1:02d}', '-metadata', f'track={i+1}/{len(tracks)}', str(root/track['file'])]
    run(command, root/'split.stderr')

    def hash_pcm(paths, log):
        joined = hashlib.sha256()
        total = 0
        results = []
        with log.open('wb') as err:
            for path in paths:
                digest, size = hashlib.sha256(), 0
                process = subprocess.Popen(common + ['-i', str(path), '-map', '0:a:0', '-c:a', 'pcm_s24le', '-f', 's24le', 'pipe:1'], stdout=subprocess.PIPE, stderr=err)
                try:
                    while block := process.stdout.read(1024*1024):
                        digest.update(block)
                        joined.update(block)
                        size += len(block)
                    if process.wait(timeout=1800):
                        raise RuntimeError('verification decode failed')
                except BaseException:
                    process.kill()
                    process.wait()
                    raise
                total += size
                results.append(dict(sha256=digest.hexdigest(), bytes=size))
        clean(log)
        return dict(sha256=joined.hexdigest(), bytes=total), results

    print('Comparing source, continuous FLAC and joined-track PCM', flush=True)
    continuous, _ = hash_pcm([full], root/'verify-continuous.stderr')
    joined, individual = hash_pcm([root/t['file'] for t in tracks], root/'verify-tracks.stderr')
    source_pcm = None if args.reset_decoder_per_cell else (root/'source-pcm.sha256').read_text().strip().split('=', 1)[1].lower()
    if (continuous != joined or (source_pcm is not None and continuous['sha256'] != source_pcm)
            or continuous['bytes'] != position*channels*3):
        raise RuntimeError('PCM equality or length check failed')
    for track, pcm in zip(tracks, individual):
        frames = track['end_frame']-track['start_frame']
        check(root/track['file'], frames)
        if pcm['bytes'] != frames*channels*3:
            raise RuntimeError('decoded track length differs')
        track['pcm'] = pcm
        if args.independent_cells:
            number, cell = track['number'], track['cell']
            print(f'Checking fresh cell decode against track {number}', flush=True)
            hashed = root/f'cell-{number:02d}.sha256'
            if not args.reset_decoder_per_cell:
                feed(common + ['-f', 'mpeg', '-i', 'pipe:0', '-map', '0:a:0', '-af', 'asetpts=N/SR/TB',
                    '-c:a', 'pcm_s24le', '-f', 'hash', '-hash', 'sha256', str(hashed)], cell['start'], cell['end'], root/f'cell-{number:02d}.stderr')
            if hashed.read_text().strip().split('=', 1)[1].lower() != pcm['sha256']:
                raise RuntimeError(f'fresh cell {number} does not match duration-based cut')
    report = dict(source=str(args.source.resolve()), inventory=str(args.inventory.resolve()), title_row=args.title_row,
                  title_navigation=title, artist=args.artist, album=args.album, presentation=args.presentation,
                  frames=position, stream=info, source_sectors_sha256=source_hash, pcm=continuous,
                  source_cell_sectors_sha256=source_cell_hashes, decoder_reset_per_cell=args.reset_decoder_per_cell,
                  accepted_navigation_resets=(root/'encode.stderr').read_text().splitlines(),
                  source_pcm_identical=True, joined_tracks_identical=True, independent_cell_decodes_identical=args.independent_cells,
                  tracks=tracks, ffmpeg_version=subprocess.check_output([ffmpeg, '-version'], text=True).splitlines()[0],
                  limits='Same FFmpeg implementation for source/FLAC decoding. ATS cuts need musical validation; no speaker-ID fixture. No resampling, ReplayGain or downmix applied.')
    (root/'listening-report.json').write_text(json.dumps(report, indent=2)+'\n')
    (root/'Tracks.m3u8').write_text('#EXTM3U\n'+'\n'.join(t['file'] for t in tracks)+'\n')
    print(json.dumps(dict(frames=position, pcm=continuous, completed=str(root)), indent=2), flush=True)


if __name__ == '__main__':
    main()
