"""Decode an extracted audio/video segment to FLAC and verify its PCM round-trip.

No decryption or navigation; accepts a completed, separately extracted segment.
"""
import argparse
import json
import pathlib
import shutil
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('source', type=pathlib.Path)
p.add_argument('output', type=pathlib.Path, help='New directory outside repository')
p.add_argument('--title', required=True)
p.add_argument('--allow-missing-video-end-pts', action='store_true', help='Accept only MPEG video stream-1 missing-end-PTS warnings')
p.add_argument('--seconds', type=float, help='Limit the listening sample to this duration')
p.add_argument('--frames', type=int, help='Expected decoded frames from navigation, if known')
args = p.parse_args()
if args.seconds is not None and args.seconds <= 0: p.error('--seconds must be positive')
trim = ['-t', str(args.seconds)] if args.seconds is not None else []
root = args.output.resolve()
repo = pathlib.Path(__file__).resolve().parents[2]
if root == repo or repo in root.parents: p.error('output must be outside repository')
ffmpeg, ffprobe = shutil.which('ffmpeg'), shutil.which('ffprobe')
if not ffmpeg or not ffprobe: p.error('ffmpeg and ffprobe required')
root.mkdir(parents=True, exist_ok=False)
common = [ffmpeg, '-hide_banner', '-v', 'warning', '-xerror', '-n']
output = root/'Audio.flac'
with (root/'encode.stderr').open('wb') as err:
    subprocess.run(common + ['-i', str(args.source), '-map', '0:a:0', '-af', 'asetpts=N/SR/TB',
        '-c:a', 'flac', '-sample_fmt', 's32', '-bits_per_raw_sample', '24', '-metadata', f'title={args.title}'] + trim + [str(output),
        '-map', '0:a:0', '-af', 'asetpts=N/SR/TB', '-c:a', 'pcm_s24le'] + trim + ['-f', 'hash', '-hash', 'sha256',
        str(root/'source.sha256')], check=True, stderr=err, stdout=subprocess.DEVNULL, timeout=600)
warnings = (root/'encode.stderr').read_text().splitlines()
if warnings and not (args.allow_missing_video_end_pts and all(
        line.startswith('[in#0/mpeg @ ') and line.endswith('stream 1 : no PTS found at end of file, duration not set')
        for line in warnings)):
    raise RuntimeError('Review encode diagnostics')
with (root/'verify.stderr').open('wb') as err:
    decoded = subprocess.check_output(common + ['-i', str(output), '-map', '0:a:0', '-c:a', 'pcm_s24le',
        '-f', 'hash', '-hash', 'sha256', '-'], stderr=err, timeout=600).decode().strip()
if decoded != (root/'source.sha256').read_text().strip(): raise RuntimeError('PCM mismatch')
if (root/'verify.stderr').stat().st_size: raise RuntimeError('Review decode diagnostics')
stream = json.loads(subprocess.check_output([ffprobe,'-v','error','-show_streams','-of','json',str(output)]))['streams'][0]
if args.frames is not None and (stream['duration_ts'] != args.frames or stream['time_base'] != '1/96000'):
    raise RuntimeError(f'Unexpected frame count: {stream}')
report = dict(source=str(args.source), title=args.title, source_pcm_identical=True, pcm_sha256=decoded,
    stream=stream, expected_frames=args.frames, limit_seconds=args.seconds, accepted_demux_warnings=warnings,
    limits='Same FFmpeg decoder used for source and FLAC. Navigation correctness and speaker routing are separate checks.')
(root/'report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:stream.get(k) for k in ['codec_name','sample_rate','channels','channel_layout','bits_per_raw_sample','duration_ts','duration']},indent=2))
print(decoded)
