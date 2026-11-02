"""Bounded ISO9660 inventory and validation of scratch libdvdread results."""
import argparse
import json
import shutil
import pathlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--images', type=pathlib.Path, required=True, help='Directory containing the two named raw images')
parser.add_argument('--output', type=pathlib.Path, required=True, help='Existing inventory report directory; also receives JSON and a media sample')
parser.add_argument('--ffprobe', default=shutil.which('ffprobe'), help='ffprobe executable')
args = parser.parse_args()
if not args.ffprobe:
    parser.error('ffprobe is required')
ROOT = args.output.resolve()
# Keep generated reports and copyrighted samples outside the repository.
repo = pathlib.Path(__file__).resolve().parents[2]
if ROOT == repo or repo in ROOT.parents:
    parser.error('--output must be outside the repository')
ROOT.mkdir(parents=True, exist_ok=True)

def iso_files(image):
    with image.open('rb') as f:
        f.seek(16 * 2048)
        pvd = f.read(2048)
        assert pvd[:7] == b'\x01CD001\x01', 'Expected ISO9660 primary descriptor'
        def record(b):
            return dict(sector=int.from_bytes(b[2:6], 'little'),
                        bytes=int.from_bytes(b[10:14], 'little'), flags=b[25])
        entries = {}
        def walk(directory, prefix='', depth=0):
            assert depth < 8 and directory['bytes'] < 4*1024*1024
            f.seek(directory['sector']*2048)
            data=f.read(directory['bytes'])
            assert len(data)==directory['bytes']
            pos=0
            while pos<len(data):
                size=data[pos]
                if not size:
                    pos=(pos//2048+1)*2048
                    continue
                b=data[pos:pos+size]; pos+=size
                assert len(b)==size and size>=34
                name=b[33:33+b[32]]
                if name in (b'\0',b'\1'): continue
                name=name.decode('ascii').split(';')[0]
                r=record(b)
                assert not r['flags'] & 128, 'Multi-extent file needs a fuller reader'
                assert r['sector']*2048+r['bytes']<=image.stat().st_size
                path=prefix+name
                entries[path]=r
                if r['flags']&2: walk(r,path+'/',depth+1)
        walk(record(pvd[156:190]))
        return entries

def fields(line):
    return {k: int(v,0) if v.startswith('0x') or v.isdigit() else v
            for k,v in (word.split('=',1) for word in line.split()[1:])}

for slug, filename in [('glen-phillips','Glen Phillips raw.iso'),('american-beauty','American Beauty DVD-A raw.iso')]:
    image=args.images/filename
    files=iso_files(image)
    rows={}
    for line in (ROOT/(slug+'.txt')).read_text().splitlines():
        rows.setdefault(line.split()[0],[]).append(fields(line))
    aobs={k:v for k,v in files.items() if k.endswith('.AOB')}
    total=sum(v['bytes']//2048 for v in aobs.values())
    titles=[]
    for title in rows['title']:
        tracks=[x for x in rows['track'] if x['title_row']==title['row']]
        cells=[x for x in rows['cell'] if x['title_row']==title['row']]
        assert all(0<=c['start']<=c['end']<total for c in cells)
        assert all(1<=t['first_cell']<=len(cells) for t in tracks)
        titles.append(dict(title, duration_seconds=title['duration_pts']/90000,
            tracks=tracks,cells=cells,
            duration_sum_matches=sum(t['duration_pts'] for t in tracks)==title['duration_pts'],
            cells_contiguous=all(b['start']==a['end']+1 for a,b in zip(cells,cells[1:]))))
    # Independently compare SAMG addresses with the title-cell addresses.
    base=files['AUDIO_TS/ATS_01_1.AOB']['sector']
    samg=[]
    for r in rows['samg_chapter']:
        matches=[dict(title_row=t['row'],cell=c['row']) for t in titles for c in t['cells']
                 if c['start']+base==r['start'] and c['end']+base==r['end']]
        samg.append(dict(**r, matching_atsi_cells=matches))
    result=dict(image=str(image),bytes=image.stat().st_size, files=files,aob_total_sectors=total,
                titles=titles,samg=samg,attributes=rows['attribute'],references=rows['reference'])
    (ROOT/(slug+'.json')).write_text(json.dumps(result,indent=2)+'\n')
    print(slug,'aob sectors',total,'base',base)
    for t in titles:
        print(' title', t['row'], 'seconds',t['duration_seconds'],'sum',t['duration_sum_matches'],
              'contiguous',t['cells_contiguous'],'range',t['cells'][0]['start'],t['cells'][-1]['end'])
    print(' samg unmatched',[r['row'] for r in samg if not r['matching_atsi_cells']])
    print(' files',json.dumps(aobs))
    # Probe only a small sample of the unprotected candidate, not the whole title.
    if slug=='glen-phillips':
        sample=ROOT/'glen-first-4MiB.aob'
        with image.open('rb') as f:
            f.seek(base*2048); sample.write_bytes(f.read(4*1024*1024))
        p=subprocess.run([args.ffprobe,'-v','error','-show_streams','-of','json',str(sample)],
                         capture_output=True,text=True,timeout=20)
        (ROOT/'glen-streams.json').write_text(p.stdout)
        (ROOT/'glen-streams.stderr').write_text(p.stderr)
        print(' ffprobe exit',p.returncode,p.stdout,p.stderr)
        p.check_returncode()
