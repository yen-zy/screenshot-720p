# Notifications + Floating Progress Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Notify when a video starts/finishes/fails converting and show live progress in a floating panel.

**Architecture:** The Python worker prints one-line JSON events on stdout; the Swift launcher reads its stdout pipe, drives a non-activating NSPanel and posts UNUserNotificationCenter notifications. `install.sh` builds, assembles, signs and swaps the app safely.

**Tech Stack:** Python 3.13 + ffmpeg 7.1 (`-progress pipe:1`), Swift 6 / AppKit / UserNotifications, launchd.

**Spec:** `docs/superpowers/specs/2026-11-18-progress-window-design.md`

## Global Constraints
- Bundle id stays `local.yen.screenshot720p`; agent label stays the same; ad-hoc signing.
- Panel: bottom-right of the screen with the mouse, ~320×70, never activates, all Spaces + full screen, `sharingType = .none`.
- Panel appears only if a job is still running 1.5 s after `start`; "Done ✓" for 3 s then fades.
- Failure notification only on a file's first failure; retries are quiet.
- No menu bar item, no Dock icon.

## Review Focus
- Video with no known duration → indeterminate bar, no crash.
- Several videos queued → "N more waiting" counts down; panel stays up between jobs.
- A file that keeps failing every 5 min → no repeat notifications.
- Worker killed mid-job (install / logout) → panel hides, no stale "42%".
- Event line split across pipe reads → Swift buffers until newline.

---

### Task 1: Python progress events
**Files:** Modify `src/screenshot_720p.py`; Test `tests/test_events.py`
**Produces (stdout, one JSON object per line):**
- `{"event":"start","file":str,"size":int,"duration":float|null,"waiting":int,"quiet":bool}`
- `{"event":"progress","file":str,"percent":float|null}` (≤ 2/s, 0–100)
- `{"event":"done","file":str,"output":str,"size":int,"output_size":int,"waiting":int}`
- `{"event":"failed","file":str,"error":str,"waiting":int}` (only when not quiet)
`quiet` = the file's previous status was `retry`.

- [ ] Tests: generate a 6 s testsrc+sine .mov in a temp folder, run the script with `--settle-seconds 0`; assert events are start → ≥1 progress (non-decreasing, ≤100) → done, output exists. Corrupt `.mov` (random bytes): first run emits `failed`; after forcing `retry_after` into the past, second run emits `start` with `quiet: true` and no `failed`.
- [ ] Run tests, see fail; implement `emit()`, ffmpeg `-progress pipe:1 -nostats` reader (stderr to temp file, 24 h kill timer); run tests, see pass.

### Task 2: Swift panel + notifications
**Files:** Modify `src/ConverterLauncher.swift`; Create `src/ProgressPanel.swift`, `src/Notifier.swift`
- `ProgressPanel`: `start(file:waiting:)`, `update(percent:)`, `finish(success:)`, `abort()`; time-left from elapsed/fraction once ≥ 5 %; click → hide until next `start`. `--shareable-panel` launch arg disables `sharingType = .none` (testing only).
- `Notifier`: `requestAuthorization()`, `converting(file:)`, `ready(output:inSize:outSize:)` (click → reveal in Finder), `failed(file:error:)`.
- Launcher: worker stdout → `Pipe`, line-buffered, decode events on main queue; on worker exit call `panel.abort()` if a job was active.
- [ ] Build with `swiftc` — no errors.

### Task 3: install.sh
Build into `build/`, assemble bundle, `codesign --force --sign -`, verify; back up installed app; wait (≤ 10 min) for any running conversion; `launchctl bootout`; wait for launcher exit; swap app; copy plist; `bootstrap`; on any error restore backup and re-bootstrap.

### Task 4: Verify
- [ ] Run the built bundle against a scratch folder with `--shareable-panel`; drop a 60 s test video; screenshot the panel; confirm notifications delivered.
- [ ] `./install.sh`; agent running; real-folder test video converts, then remove test files.
