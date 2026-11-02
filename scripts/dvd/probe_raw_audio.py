"""Probe bounded, undecrypted AOB samples from each inventoried ATS title row.

For the single-title-set test images only. Reads files, never physical drives.
Scrambling flags plus decode errors are evidence, not a decryption test.
"""
import argparse
import collections
import json
import pathlib
import shutil
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('inventory', type=pathlib.Path)
p.add_argument('output', type=pathlib.Path, help='New directory outside the repository')
args = p.parse_args()
root = args.output.resolve()
repo = pathlib.Path(__file__).resolve().parents[2]
if root == repo or repo in root.parents:
    p.error('media output must be outside the repository')
ffmpeg = shutil.which('ffmpeg')
if not ffmpeg:
    p.error('ffmpeg required')
d = json.loads(args.inventory.read_text())
parts = [v for k,v in sorted(d['files'].items()) if k.startswith('AUDIO_TS/ATS_01_') and k.endswith('.AOB')]
root.mkdir(parents=True, exist_ok=False)
report = []
with open(d['image'], 'rb') as image:
    for title in d['titles']:
        skip = title['cells'][0]['start'] * 2048
        remaining = min(4*1024*1024, (title['cells'][0]['end']-title['cells'][0]['start']+1)*2048)
        sample = bytearray()
        for part in parts:
            if skip >= part['bytes']:
                skip -= part['bytes']; continue
            amount = min(remaining, part['bytes']-skip)
            image.seek(part['sector']*2048+skip)
            block = image.read(amount)
            if len(block) != amount:
                raise RuntimeError('short image read')
            sample.extend(block); remaining -= amount; skip = 0
            if not remaining: break
        if remaining: raise RuntimeError('sample exceeds inventoried AOB extents')
        name = f'title-row-{title["row"]}'
        path = root/(name+'.aob')
        path.write_bytes(sample)
        controls = collections.Counter()
        for offset in range(0, len(sample), 2048):
            sector = sample[offset:offset+2048]
            # Bounded scan of the clear sector header for private_stream_1 PES.
            i = sector.find(b'\x00\x00\x01\xbd', 0, 128)
            if i >= 0:
                controls[(sector[i+6] >> 4) & 3] += 1
        result = subprocess.run([ffmpeg, '-hide_banner', '-v', 'error', '-xerror', '-i', str(path),
            '-map', '0:a:0', '-t', '1', '-f', 'null', '-'], capture_output=True, timeout=20)
        (root/(name+'.stderr')).write_bytes(result.stderr)
        report.append(dict(title_row=title['row'], sample_bytes=len(sample), pes_scrambling_controls=dict(controls),
                           direct_decode_exit=result.returncode, diagnostics=result.stderr.decode(errors='replace')[:2000]))
(root/'report.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report, indent=2))
