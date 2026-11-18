# Notifications + floating progress window — design

## Why
The converter runs silently. You want to know when a video in
`~/Documents/Screenshot` has been picked up, see how far along the
conversion is, and know when the 720p copy is ready. The menu bar is
already crowded, so progress goes in a small floating window instead.

## Goals
- A Mac notification when a video starts converting.
- A small floating window with live progress while it converts.
- A notification when it finishes (click → shows the file in Finder) or fails.

## Non-goals / anti-goals
- No menu bar icon, no Dock icon.
- The window must never steal focus, block clicks on what's behind it for
  long, or show up in your own screen recordings.
- Retries of a failing file (every 5 min) must not re-notify each time.

## Approaches (decided)
- Menu bar icon: rejected, too many icons already.
- Dock progress bar / milestone notifications: rejected (jumpy / noisy).
- **Floating mini window: chosen.**

## Design
**Floating window** — bottom-right corner of the screen you're using,
about 320×70, rounded, translucent:

    ┌──────────────────────────────────┐
    │ ▶ IMG_8566.mov            42%    │
    │ ▓▓▓▓▓▓▓▓░░░░░░░░░░  ~1 min left  │
    │ 2 more waiting                   │
    └──────────────────────────────────┘

- Appears only while converting; shows "Done ✓" for 3 s, then fades out.
- Floats above normal windows, on every Space and over full-screen apps,
  never takes focus. Click it to hide it until the next video.
- Excluded from screenshots and screen recordings (window sharing type
  set to none), so it can't end up in the videos you're recording.
- Skipped entirely for very quick jobs: it only appears if a conversion
  is still running after ~1.5 s (most screen recordings finish in 2–7 s,
  so short ones may just flash the notifications).

**Notifications** (macOS asks once for permission):
- "Converting IMG_8566.mov" when a conversion starts.
- "IMG_8566_720p.mp4 is ready — 307 MB → 8.4 MB"; click reveals it in Finder.
- "Couldn't convert IMG_8566.mov" with a short reason — only the first
  time a file fails, not on every retry.

**How progress gets to the window**
- The Python script runs ffmpeg with `-progress` and compares the time
  encoded against the video's length to get a percentage.
- It prints one-line JSON events to its output: `start`, `progress`,
  `done`, `failed` (plus how many videos are still waiting).
- The Swift background app reads those lines and updates the window and
  notifications. Logging stays as it is.

**Project / install**
- Source now lives in `~/Developer/screenshot-720p` (`src/`, `support/`).
- An `install.sh` builds the Swift app, assembles the bundle, signs it,
  stops the running agent (waiting for any conversion in progress),
  installs to /Applications, and restarts it. The installed app is backed up
  first so it can be rolled back.

## Left to the builder
Exact colors/fonts (follow system light/dark), time-left smoothing, and
notification wording details.

## Risk to check first
The app is self-signed ("ad-hoc"). macOS normally allows notifications
for it, but if it refuses, the fallback is notifications without the
click-to-reveal action.
