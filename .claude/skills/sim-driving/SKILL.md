---
name: sim-driving
description: Drive the visionOS simulator hands-free — synthetic clicks, screenshots, coordinate mapping, and log reading for live-testing VisionPlex without asking the user to interact.
---

# Driving the visionOS simulator

Claude can exercise the app's UI itself: screenshot → locate target → synthetic click →
screenshot/logs to verify. Use this for anything reachable by tap. Still hand off to the
user for gaze-hover effects (a real cursor hover ≠ gaze highlight rendering in all cases),
pinch-drag gestures, and anything in the EXPANDED cinema scene (system-owned).

## The click helper

`scripts/simclick.swift` posts a real CGEvent mouse move + left click at **screen**
coordinates (a click = gaze+pinch in the visionOS sim). Compile once per session:

```sh
swiftc -O scripts/simclick.swift -o /tmp/simclick
```

AppleScript `System Events → click at` does NOT work (no real CGEvents). Caveats:

- The Simulator window must be **frontmost**: run
  `osascript -e 'tell application "Simulator" to activate'` and sleep ~0.5s before every
  click (a click without prior activation is silently swallowed — verified).
- It commandeers the user's real mouse for ~0.5s per click. Warn the user before a long
  clicking sequence so they keep hands off.

## Coordinate mapping (device px → screen pt)

Screenshots are full device resolution (3840×2160). The Simulator window letterboxes the
16:9 content below its title bar. Get the window frame, then map:

```sh
osascript -e 'tell application "System Events" to tell process "Simulator" to get {position, size} of window 1'
# → {winX, winY, winW, winH}   e.g. 10, 51, 1708, 1013
```

```
scale     = winW / 3840
contentTop = winY + (winH − 2160·scale)     # title-bar offset; content is bottom-anchored
screenX   = winX + deviceX·scale
screenY   = contentTop + deviceY·scale
```

At the usual window size, scale ≈ 0.445 — a poster-sized target is forgiving, but small
controls (back chevron ≈ 11pt radius on screen) need device coords accurate to ~±20px.
**Don't eyeball small targets from the downscaled Read preview** (599px wide, ≈6.4× off);
crop the full-res PNG around the estimate first:

```sh
sips --cropToHeightWidth 300 400 --cropOffset <devY-150> <devX-200> shot.png --out /tmp/crop.png
```

then Read the crop (rendered ~1:1) and refine the center.

## Screenshot + logs (verify every click)

```sh
xcrun simctl io booted screenshot /tmp/visionplex-test.png   # then Read it
xcrun simctl spawn booted log show --last 5m --predicate 'process == "PlexAVPApp"'
```

After a click, sleep ~2s before screenshotting (navigation/animation settles). If a click
seems to no-op: re-check Simulator was frontmost, then re-derive coords from a fresh crop —
those two cover every miss seen so far.

## Standard loop

1. Build + install + relaunch (commands in CLAUDE.md).
2. Screenshot → Read → pick target → map coords (crop to refine if small).
3. Activate Simulator → `/tmp/simclick X Y` → sleep 2 → screenshot → verify.
4. For speculative fixes, add NSLog first (`NSLog("%@", str)` — never raw `%`) and read
   the log after exercising the path.
