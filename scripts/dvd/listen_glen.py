"""One-off Glen Phillips presentation extraction and provisional ATS track splitting.

Requires the JSON from inspect_images.py. This assumes its verified, contiguous,
unprotected, single-title-set 96 kHz/24-bit/5.1 program, not arbitrary DVDs.
"""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('inventory', type=pathlib.Path)
parser.add_argument('output', type=pathlib.Path, help='New directory outside the repository')
parser.add_argument('--presentation', choices=['surround', 'stereo'], default='surround')
args = parser.parse_args()
channels = 2 if args.presentation == 'stereo' else 6
layout = 'stereo' if channels == 2 else '5.1'
decoder_options = ['-downmix', 'stereo'] if channels == 2 else []
root = args.output.resolve()
repo = pathlib.Path(__file__).resolve().parents[2]
if root == repo or repo in root.parents:
    parser.error('media output must be outside the repository')
ffmpeg, ffprobe = shutil.which('ffmpeg'), shutil.which('ffprobe')
if not ffmpeg or not ffprobe:
    parser.error('ffmpeg and ffprobe required')
data = json.loads(args.inventory.read_text())
image = pathlib.Path(data['image'])
title = data['titles'][0]
if ('Glen Phillips' not in image.name or image.stat().st_size != data['bytes']
        or len(title['tracks']) != 11 or not title['cells_contiguous']):
    parser.error('expected the inventoried Glen Phillips image and contiguous 11-track program')
ends = []
position = 0
for track in title['tracks']:
    numerator = track['duration_pts'] * 96000
    if numerator % 90000:
        parser.error('track duration does not resolve to an integer sample count')
    position += numerator // 90000
    ends.append(position)
root.mkdir(parents=True, exist_ok=False)
common = [ffmpeg, '-hide_banner', '-v', 'warning', '-xerror', '-n']
full = root/f'Glen Phillips - {layout}.flac'
partial = root/'continuous.partial.flac'
log = root/'extraction.log'
print(f'Reading AOB extents and encoding continuous {layout} FLAC...', flush=True)
with log.open('wb') as err:
    process = subprocess.Popen(common + decoder_options + ['-f', 'mpeg', '-i', 'pipe:0', '-map', '0:a:0',
        '-af', 'asetpts=N/SR/TB', '-c:a', 'flac', '-sample_fmt', 's32', '-bits_per_raw_sample', '24',
        '-metadata', 'artist=Glen Phillips', '-metadata', f'title=DVD-Audio {layout} program', str(partial),
        '-map', '0:a:0', '-af', 'asetpts=N/SR/TB', '-c:a', 'pcm_s24le',
        '-f', 'hash', '-hash', 'sha256', str(root/'source-pcm.sha256')],
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=err)
    try:
        with image.open('rb') as source:
            for name, extent in sorted(data['files'].items()):
                if not name.startswith('AUDIO_TS/ATS_01_') or not name.endswith('.AOB'):
                    continue
                source.seek(extent['sector']*2048)
                remaining = extent['bytes']
                while remaining:
                    block = source.read(min(1024*1024, remaining))
                    if not block:
                        raise RuntimeError('short image read')
                    process.stdin.write(block)
                    remaining -= len(block)
        process.stdin.close()
        if process.wait() != 0:
            raise RuntimeError('decoder/encoder failed; see extraction.log')
    except BaseException:
        process.kill(); process.wait()
        raise
if log.stat().st_size:
    raise RuntimeError('decoder diagnostics require review; see extraction.log')
info = json.loads(subprocess.check_output([ffprobe, '-v', 'error', '-show_streams',
                                          '-of', 'json', str(partial)]))['streams'][0]
for key, expected in dict(codec_name='flac', sample_rate='96000', channels=channels,
                          channel_layout=layout, bits_per_raw_sample='24').items():
    if info.get(key) != expected:
        raise RuntimeError(f'unexpected format: {key}={info.get(key)}')
actual_frames = int(info['duration_ts'])  # checked time base below
if info['time_base'] != '1/96000' or actual_frames != position:
    raise RuntimeError(f'Navigation predicts {position} frames, decoded {actual_frames}; keep continuous.partial.flac for investigation')
partial.rename(full)
print(f'Continuous decode matches navigation length: {position} frames. Splitting...', flush=True)
filters = ['[0:a]asplit=11' + ''.join(f'[s{i}]' for i in range(11))]
start = 0
tracks = []
for i, end in enumerate(ends):
    filters.append(f'[s{i}]atrim=start_sample={start}:end_sample={end},asetpts=N/SR/TB[t{i}]')
    tracks.append(dict(number=i+1, start_frame=start, end_frame=end, file=f'{i+1:02d} - Track {i+1:02d}.flac'))
    start = end
command = common + ['-i', str(full), '-filter_complex', ';'.join(filters)]
for i, track in enumerate(tracks):
    command += ['-map', f'[t{i}]', '-c:a', 'flac', '-sample_fmt', 's32', '-bits_per_raw_sample', '24',
        '-metadata', 'artist=Glen Phillips', '-metadata', f'title=Track {i+1:02d}', '-metadata', f'track={i+1}/11',
        str(root/track['file'])]
with (root/'split.log').open('wb') as err:
    subprocess.run(command, stdout=subprocess.DEVNULL, stderr=err, check=True)
if (root/'split.log').stat().st_size:
    raise RuntimeError('split diagnostics require review')

def pcm_hash(paths):
    digest = hashlib.sha256()
    count = 0
    with (root/'verification.log').open('ab') as err:
        for path in paths:
            p = subprocess.Popen(common + ['-i', str(path), '-map', '0:a:0', '-c:a', 'pcm_s24le',
                '-f', 's24le', 'pipe:1'], stdout=subprocess.PIPE, stderr=err)
            try:
                while block := p.stdout.read(1024*1024):
                    digest.update(block); count += len(block)
                if p.wait() != 0:
                    raise RuntimeError('verification decode failed')
            except BaseException:
                p.kill(); p.wait(); raise
    return dict(sha256=digest.hexdigest(), bytes=count)

print('Comparing continuous PCM with joined track PCM...', flush=True)
continuous = pcm_hash([full])
joined = pcm_hash([root/t['file'] for t in tracks])
if continuous != joined or continuous['bytes'] != position*channels*3 or (root/'verification.log').stat().st_size:
    raise RuntimeError('track joins or PCM length did not verify')
source_hash = (root/'source-pcm.sha256').read_text().strip().split('=', 1)[1].lower()
if source_hash != continuous['sha256']:
    raise RuntimeError('Source MLP PCM differs from FLAC PCM')
for track in tracks:
    stream = json.loads(subprocess.check_output([ffprobe, '-v', 'error', '-show_streams', '-of', 'json',
                                                str(root/track['file'])]))['streams'][0]
    if (stream['time_base'] != '1/96000' or stream['duration_ts'] != track['end_frame']-track['start_frame']
            or stream['channels'] != channels or stream['bits_per_raw_sample'] != '24'):
        raise RuntimeError(f'Unexpected track format or duration: {track}')
report = dict(source=str(image), presentation=args.presentation, sample_rate=96000, valid_bits=24, channels=channels, layout=layout,
    frames=position, pcm=continuous, source_pcm_identical=True, joined_tracks_identical=True, tracks=tracks,
    limitations='Cuts derived from ATS durations; musical boundaries and authored presentation selection need listening/packet validation. No channel-ID fixture tested.')
(root/'listening-report.json').write_text(json.dumps(report, indent=2)+'\n')
(root/'Glen Phillips - tracks.m3u8').write_text('#EXTM3U\n'+'\n'.join(t['file'] for t in tracks)+'\n')
print(json.dumps(report, indent=2), flush=True)
