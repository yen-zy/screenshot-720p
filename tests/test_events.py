"""End-to-end tests for the JSON events the worker prints on stdout."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / 'src' / 'screenshot_720p.py'
PYTHON = '/Library/Frameworks/Python.framework/Versions/3.13/bin/python3'
FFMPEG = '/opt/homebrew/bin/ffmpeg'


def run_worker(folder, state):
    result = subprocess.run(
        [PYTHON, str(SCRIPT), '--folder', str(folder), '--state-dir', str(state),
         '--settle-seconds', '0'],
        capture_output=True, text=True, timeout=300)
    events = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    return result, events


class EventTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.folder = base / 'in'
        self.state = base / 'state'
        self.folder.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def make_video(self, name, seconds=6):
        path = self.folder / name
        subprocess.run([FFMPEG, '-v', 'error', '-f', 'lavfi', '-i',
                        f'testsrc2=size=1920x1080:rate=30:duration={seconds}',
                        '-f', 'lavfi', '-i', f'sine=frequency=440:duration={seconds}',
                        '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac',
                        '-shortest', str(path)], check=True)
        old = path.stat().st_mtime - 10
        os.utime(path, (old, old))
        return path

    def test_successful_conversion_emits_start_progress_done(self):
        self.make_video('clip.mov')
        result, events = run_worker(self.folder, self.state)
        self.assertEqual(result.returncode, 0, result.stderr)
        kinds = [e['event'] for e in events]
        self.assertEqual(kinds[0], 'start')
        self.assertEqual(kinds[-1], 'done')
        start, done = events[0], events[-1]
        self.assertEqual(start['file'], 'clip.mov')
        self.assertFalse(start['quiet'])
        self.assertEqual(start['waiting'], 0)
        self.assertAlmostEqual(start['duration'], 6, delta=0.5)
        progress = [e['percent'] for e in events if e['event'] == 'progress']
        self.assertTrue(progress, 'expected at least one progress event')
        self.assertEqual(progress, sorted(progress))
        self.assertTrue(all(0 <= p <= 100 for p in progress))
        self.assertTrue(Path(done['output']).exists())
        self.assertEqual(done['output_size'], Path(done['output']).stat().st_size)
        self.assertGreater(done['size'], 0)

    def test_waiting_counts_down_across_queue(self):
        self.make_video('a.mov', 2)
        self.make_video('b.mov', 2)
        _, events = run_worker(self.folder, self.state)
        starts = [e for e in events if e['event'] == 'start']
        self.assertEqual([s['waiting'] for s in starts], [1, 0])

    def test_failure_notifies_once_then_retries_quietly(self):
        bad = self.folder / 'broken.mov'
        bad.write_bytes(os.urandom(4096))
        old = bad.stat().st_mtime - 10
        os.utime(bad, (old, old))
        _, first = run_worker(self.folder, self.state)
        self.assertIn('failed', [e['event'] for e in first])

        state_path = self.state / 'state.json'
        state = json.loads(state_path.read_text())
        for record in state['files'].values():
            record['retry_after'] = 0
        state_path.write_text(json.dumps(state))

        _, second = run_worker(self.folder, self.state)
        self.assertNotIn('failed', [e['event'] for e in second])
        starts = [e for e in second if e['event'] == 'start']
        self.assertTrue(all(s['quiet'] for s in starts))


if __name__ == '__main__':
    unittest.main()
