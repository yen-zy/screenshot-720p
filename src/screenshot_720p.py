#!/usr/bin/env python3
"""Make non-destructive 720p copies of videos in one folder."""

import argparse
import fcntl
import hashlib
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
import time
import uuid

FFMPEG = '/opt/homebrew/bin/ffmpeg'
FFPROBE = '/opt/homebrew/bin/ffprobe'
VIDEO_SUFFIXES = {'.mov', '.mp4', '.m4v', '.mkv', '.avi', '.webm', '.mpg',
                  '.mpeg', '.mts', '.m2ts', '.ts', '.3gp', '.3g2', '.mxf',
                  '.flv', '.wmv', '.vob', '.ogv'}
LOG = logging.getLogger('screenshot-720p')
ACTIVE_ENCODER = None


def stop_worker(signum, frame):
    if ACTIVE_ENCODER is not None and ACTIVE_ENCODER.poll() is None:
        try:
            os.killpg(ACTIVE_ENCODER.pid, signal.SIGTERM)
            ACTIVE_ENCODER.wait(timeout=5)
        except ProcessLookupError:
            pass
        except subprocess.TimeoutExpired:
            os.killpg(ACTIVE_ENCODER.pid, signal.SIGKILL)
            ACTIVE_ENCODER.wait()
    raise SystemExit(0)


def signature(path):
    s = path.stat()
    return [s.st_ino, s.st_size, s.st_mtime_ns]


def read_state(path):
    if not path.exists():
        return {'files': {}}
    return json.loads(path.read_text())


def save_state(path, state):
    temp = path.with_suffix('.json.tmp')
    temp.write_text(json.dumps(state, indent=2, ensure_ascii=False))
    os.replace(temp, path)


def probe(path):
    result = subprocess.run(
        [FFPROBE, '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(path)],
        capture_output=True, text=True, timeout=60, check=True)
    return json.loads(result.stdout)


def video_stream(info):
    return next(s for s in info['streams'] if s.get('codec_type') == 'video'
                and not s.get('disposition', {}).get('attached_pic'))


def decodable_audio(info):
    # iPhone videos can carry an extra Apple spatial audio track (APAC) that
    # ffmpeg reports as codec "unknown" and cannot decode; skip such tracks.
    return [s for s in info['streams'] if s.get('codec_type') == 'audio'
            and s.get('codec_name') not in (None, '', 'unknown')]


def open_for_writing(path):
    result = subprocess.run(['/usr/sbin/lsof', '-Ffa', '--', str(path)],
                            capture_output=True, text=True, timeout=15)
    if result.returncode not in (0, 1):
        raise RuntimeError('Could not check whether the source is still being written')
    return any(line in ('aw', 'au') for line in result.stdout.splitlines())


def output_valid(path, source_info=None):
    try:
        info = probe(path)
        v = video_stream(info)
        if (v.get('codec_name') != 'h264' or
                not (0 < v['width'] <= 1280 and 0 < v['height'] <= 720)):
            return False
        if source_info:
            old_duration = float(source_info.get('format', {}).get('duration', 0))
            new_duration = float(info.get('format', {}).get('duration', 0))
            if old_duration and abs(new_duration - old_duration) > max(1, old_duration * 0.02):
                return False
            audio_count = lambda data: sum(s.get('codec_type') == 'audio' for s in data['streams'])
            if audio_count(info) != len(decodable_audio(source_info)):
                return False
        return True
    except (OSError, ValueError, KeyError, StopIteration, subprocess.SubprocessError):
        return False


def emit(event, **fields):
    """Print one JSON event line on stdout for the launcher app to display."""
    try:
        print(json.dumps({'event': event, **fields}, ensure_ascii=False), flush=True)
    except (BrokenPipeError, OSError):
        pass


def media_duration(info):
    try:
        value = float(info.get('format', {}).get('duration', 0))
    except (TypeError, ValueError):
        return None
    return value if value > 0 else None


def kill_group(process, flag=None):
    if flag is not None:
        flag.set()
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def report_progress(lines, name, duration, interval=0.5):
    """Read ffmpeg -progress output and emit throttled percentage events."""
    last_sent = None
    last_percent = -1.0
    for line in lines:
        key, _, value = line.strip().partition('=')
        if key != 'out_time_us' or not duration:
            continue
        try:
            seconds = int(value) / 1_000_000
        except ValueError:
            continue
        percent = round(max(0.0, min(100.0, seconds / duration * 100)), 1)
        now = time.monotonic()
        if percent > last_percent and (last_sent is None or now - last_sent >= interval):
            emit('progress', file=name, percent=percent)
            last_sent, last_percent = now, percent


def convert(source, output_dir, expected_signature, waiting=0, quiet=False):
    global ACTIVE_ENCODER
    info = probe(source)
    video = video_stream(info)
    scale = "scale=w='min(1280,iw)':h='min(720,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos,setsar=1"
    hdr = video.get('color_transfer') in ('smpte2084', 'arib-std-b67')
    filters = scale
    if hdr:
        filters = ('zscale=t=linear:npl=100,format=gbrpf32le,'
                   'tonemap=tonemap=hable:desat=0,'
                   'zscale=p=bt709:t=bt709:m=bt709:r=tv,format=yuv420p,' + scale)
    output_dir.mkdir(exist_ok=True)
    temporary = output_dir / ('.converting-' + uuid.uuid4().hex + '.mp4')
    target = output_dir / (source.stem + '_720p.mp4')
    if target.exists():
        digest = hashlib.sha256((str(source) + str(expected_signature)).encode()).hexdigest()[:10]
        target = output_dir / (source.stem + '_720p_' + digest + '.mp4')
    if target.exists():
        target = output_dir / (source.stem + '_720p_' + uuid.uuid4().hex[:10] + '.mp4')
    command = [FFMPEG, '-nostdin', '-hide_banner', '-loglevel', 'error', '-n',
               '-i', str(source), '-map', '0:' + str(video['index'])]
    for audio in decodable_audio(info):
        command += ['-map', '0:' + str(audio['index'])]
    command += ['-sn', '-dn', '-vf', filters, '-c:v', 'libx264', '-preset', 'veryfast',
               '-crf', '24', '-threads', '4', '-filter_threads', '2', '-pix_fmt', 'yuv420p',
               '-c:a', 'aac', '-b:a', '128k', '-movflags', '+faststart', '-map_metadata', '0']
    if hdr:
        command += ['-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709']
    command += ['-progress', 'pipe:1', '-nostats', str(temporary)]
    duration = media_duration(info)
    LOG.info('Converting %s', source.name)
    emit('start', file=source.name, size=source.stat().st_size, duration=duration,
         waiting=waiting, quiet=quiet)
    try:
        with tempfile.TemporaryFile(mode='w+') as errors:
            ACTIVE_ENCODER = subprocess.Popen(command, stdout=subprocess.PIPE,
                                              stderr=errors, text=True,
                                              start_new_session=True)
            timed_out = threading.Event()
            watchdog = threading.Timer(86400, kill_group, args=(ACTIVE_ENCODER, timed_out))
            watchdog.daemon = True
            watchdog.start()
            try:
                report_progress(ACTIVE_ENCODER.stdout, source.name, duration)
                ACTIVE_ENCODER.wait()
            finally:
                watchdog.cancel()
            if timed_out.is_set():
                raise RuntimeError('Conversion took longer than 24 hours')
            if ACTIVE_ENCODER.returncode:
                errors.seek(0)
                raise RuntimeError(errors.read()[-2500:].strip())
        if signature(source) != expected_signature or open_for_writing(source):
            raise RuntimeError('Source changed during conversion; will retry later')
        if not output_valid(temporary, info):
            raise RuntimeError('Output did not pass resolution, duration, or audio verification')
        # Atomic publication without overwriting any existing user file.
        os.link(temporary, target)
        LOG.info('Saved %s', target.name)
        return target
    finally:
        ACTIVE_ENCODER = None
        temporary.unlink(missing_ok=True)


def scan(folder, state_dir, settle_seconds):
    state_dir.mkdir(parents=True, exist_ok=True)
    with (state_dir / 'worker.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        sources = sorted(p for p in folder.iterdir() if not p.is_symlink()
                         and not p.name.startswith('.') and p.suffix.lower() in VIDEO_SUFFIXES
                         and p.is_file())
        (folder / '720p').mkdir(exist_ok=True)
        state_path = state_dir / 'state.json'
        state = read_state(state_path)
        records = state['files']
        next_checks = []
        todo = [str(s) for s in sources
                if records.get(str(s), {}).get('status') != 'complete'
                or records[str(s)].get('signature') != signature(s)]
        for source in sources:
            key = str(source)
            sig = signature(source)
            now = time.time()
            record = records.get(key)
            if not record or record.get('signature') != sig:
                record = {'signature': sig, 'stable_since': now, 'status': 'waiting'}
                records[key] = record
            if record.get('status') == 'complete':
                output = Path(record['output'])
                if output.exists() and signature(output) == record.get('output_signature'):
                    continue
                if output.exists() and output_valid(output):
                    record['output_signature'] = signature(output)
                    continue
                record['status'] = 'waiting'
            if not sig[1]:
                if open_for_writing(source):
                    next_checks.append(now + 2)
                continue
            ready_at = max(record['stable_since'] + settle_seconds,
                           source.stat().st_mtime + settle_seconds,
                           record.get('retry_after', 0))
            if now < ready_at:
                next_checks.append(ready_at + 0.1)
                continue
            quiet = record.get('status') == 'retry'
            waiting = len(todo) - todo.index(key) - 1 if key in todo else 0
            try:
                if open_for_writing(source):
                    next_checks.append(now + 2)
                    continue
                output = convert(source, folder / '720p', sig, waiting=waiting, quiet=quiet)
                record.update(status='complete', output=str(output),
                              output_signature=signature(output), completed_at=time.time())
                record.pop('error', None)
                record.pop('retry_after', None)
                emit('done', file=source.name, output=str(output), size=sig[1],
                     output_size=output.stat().st_size, waiting=waiting)
            except (OSError, ValueError, KeyError, StopIteration, RuntimeError, subprocess.SubprocessError) as error:
                LOG.error('%s: %s', source.name, error)
                if not quiet:
                    emit('failed', file=source.name, error=str(error).splitlines()[0][:200] if str(error) else 'Unknown error',
                         waiting=waiting)
                else:
                    emit('retry_failed', file=source.name, waiting=waiting)
                record.update(status='retry', error=str(error), retry_after=time.time() + 300)
                next_checks.append(record['retry_after'])
            save_state(state_path, state)
        state.update(last_scan=time.time(), video_count=len(sources), folder=str(folder),
                     next_check_at=min(next_checks) if next_checks else None)
        save_state(state_path, state)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--folder', type=Path, required=True)
    parser.add_argument('--state-dir', type=Path, required=True)
    parser.add_argument('--settle-seconds', type=int, default=2)
    args = parser.parse_args()
    args.state_dir.mkdir(parents=True, exist_ok=True)
    handler = RotatingFileHandler(args.state_dir / 'converter.log', maxBytes=1024 * 1024, backupCount=2)
    handler.setFormatter(logging.Formatter('%(asctime)s %(levelname)s %(message)s'))
    LOG.addHandler(handler)
    LOG.addHandler(logging.StreamHandler())
    LOG.setLevel(logging.INFO)
    signal.signal(signal.SIGTERM, stop_worker)
    signal.signal(signal.SIGINT, stop_worker)
    try:
        scan(args.folder, args.state_dir, args.settle_seconds)
    except Exception:
        LOG.exception('Folder scan failed')
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
