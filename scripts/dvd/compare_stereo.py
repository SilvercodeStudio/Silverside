"""Compare authored stereo with FFmpeg's default downmix of matching surround PCM.

Produces two 30-second FLAC listening clips from 60 seconds into the program,
plus numerical differences. Differences do not establish which sounds better.
"""
import argparse
import array
import hashlib
import json
import math
import pathlib
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('authored', type=pathlib.Path)
parser.add_argument('surround', type=pathlib.Path)
parser.add_argument('output', type=pathlib.Path, help='New directory outside the repository')
args = parser.parse_args()
root = args.output.resolve()
repo = pathlib.Path(__file__).resolve().parents[2]
if root == repo or repo in root.parents:
    parser.error('output must be outside the repository')
ffmpeg = shutil.which('ffmpeg')
if not ffmpeg:
    parser.error('ffmpeg required')
root.mkdir(parents=True, exist_ok=False)
common = [ffmpeg, '-hide_banner', '-v', 'warning', '-xerror', '-n']

def run(command):
    p = subprocess.run(command, capture_output=True, timeout=60, check=True)
    if p.stderr:
        raise RuntimeError(p.stderr.decode(errors='replace')[:2000])
    return p.stdout

clips = []
for name, source, options in [('Authored stereo', args.authored, []),
                              ('FFmpeg default downmix', args.surround, ['-ac', '2'])]:
    output = root/(name+'.flac')
    run(common + ['-ss', '60', '-i', str(source), '-map', '0:a:0', '-t', '30'] + options +
        ['-c:a', 'flac', '-sample_fmt', 's32', '-bits_per_raw_sample', '24', '-metadata', f'title={name} - 60 to 90 seconds', str(output)])
    raw = run(common + ['-i', str(output), '-map', '0:a:0', '-c:a', 'pcm_s32le', '-f', 's32le', 'pipe:1'])
    values = array.array('i', raw)
    if sys.byteorder != 'little':
        values.byteswap()
    if values.itemsize != 4 or len(values) != 30*96000*2:
        raise RuntimeError('unexpected PCM size')
    clips.append((values, hashlib.sha256(raw).hexdigest()))
a, b = clips[0][0], clips[1][0]
metrics = []
for channel in range(2):
    aa = bb = ab = difference = 0.0
    equal = 0
    for x, y in zip(a[channel::2], b[channel::2]):
        aa += x*x; bb += y*y; ab += x*y
        difference += (x-y)*(x-y)
        equal += x == y
    gain = ab/bb if bb else None
    residual = max(0.0, aa - ab*ab/bb) if bb else aa
    metrics.append(dict(channel=['left','right'][channel], identical_samples=equal,
        correlation=ab/math.sqrt(aa*bb) if aa and bb else None,
        gain_fitting_generic_to_authored=gain,
        residual_rms_relative_to_authored=math.sqrt(residual/aa) if aa else None,
        difference_rms_dbfs=10*math.log10(difference/(len(a)//2)/(2**31)**2) if difference else None))
report = dict(start_seconds=60, duration_seconds=30, sample_rate=96000,
    ffmpeg_version=run([ffmpeg,'-version']).decode().splitlines()[0],
    authored_sha256_s32le=clips[0][1], generic_sha256_s32le=clips[1][1],
    identical=clips[0][1]==clips[1][1], channels=metrics,
    interpretation='A sample comparison, not a quality ranking or proof of all presentation metadata.')
(root/'comparison.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report, indent=2))
