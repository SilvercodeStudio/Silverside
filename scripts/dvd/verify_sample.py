"""Verify three seconds of the Glen Phillips MLP sample through multichannel FLAC."""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('sample', type=pathlib.Path)
parser.add_argument('output', type=pathlib.Path, help='New FLAC path outside the repository')
args = parser.parse_args()
repo = pathlib.Path(__file__).resolve().parents[2]
output = args.output.resolve()
if output == repo or repo in output.parents:
    parser.error('output must be outside the repository')
ffmpeg, ffprobe = shutil.which('ffmpeg'), shutil.which('ffprobe')
if not ffmpeg or not ffprobe:
    parser.error('ffmpeg and ffprobe are required')

def run(command):
    result = subprocess.run(command, capture_output=True, timeout=30, check=True)
    if result.stderr:
        raise RuntimeError(result.stderr.decode(errors='replace')[:2000])
    return result.stdout

common = [ffmpeg, '-hide_banner', '-v', 'error', '-xerror']
run(common + ['-n', '-i', str(args.sample), '-map', '0:a:0', '-af', 'asetpts=N/SR/TB', '-t', '3',
              '-c:a', 'flac', '-sample_fmt', 's32', '-bits_per_raw_sample', '24', str(output)])
info = json.loads(run([ffprobe, '-v', 'error', '-select_streams', 'a:0',
                      '-show_streams', '-of', 'json', str(output)]))['streams'][0]
expected = dict(codec_name='flac', sample_rate='96000', channels=6,
                channel_layout='5.1', bits_per_raw_sample='24')
for key, value in expected.items():
    if info.get(key) != value:
        raise RuntimeError(f'{key}: expected {value}, got {info.get(key)}')

def pcm(path):
    return run(common + ['-i', str(path), '-map', '0:a:0', '-af', 'asetpts=N/SR/TB', '-t', '3',
                         '-c:a', 'pcm_s24le', '-f', 's24le', 'pipe:1'])

original, decoded = pcm(args.sample), pcm(output)
if original != decoded or len(original) != 3 * 96000 * 6 * 3:
    raise RuntimeError('PCM differs or has an unexpected sample count')
print(json.dumps(dict(format=expected, frames=288000, pcm_bytes=len(decoded),
                      pcm_sha256=hashlib.sha256(decoded).hexdigest(), identical=True), indent=2))
