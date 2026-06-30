---
name: sim-driving
description: Drive the visionOS simulator hands-free — synthetic clicks, screenshots, coordinate mapping, and log reading for live-testing VisionPlay without asking the user to interact.
---

# Driving the visionOS simulator

> **⛔ STATUS: NOT USABLE right now (user decision, 2026-06-10).** Clicks proved too
> unreliable — repeated misses/swallowed clicks even with correct coordinates — and the
> mouse takeover disrupts the user. Do NOT use the click helper for testing; the user
> drives all simulator interaction. The passive parts (screenshots, log reading,
> crop-to-measure) remain fine and expected. Revisit only if the user asks.

Claude can exercise the app's UI itself: screenshot → locate target → synthetic click →
screenshot/logs to verify. Use this for anything reachable by tap — including the
EXPANDED cinema scene's SYSTEM chrome (tab strip, transport, Close pill): clicks are
real gaze+pinch input, so they work there (verified live; it's only *app-process*
overlays that the expanded scene never receives). Still hand off to the user for
gaze-hover effects (a real cursor hover ≠ gaze highlight rendering in all cases) and
pinch-drag gestures.

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

## If the Simulator window is missing

The device can stay booted with its window closed (`window 1 … Invalid index`).
`open -a Simulator` does NOT reopen it. Reopen via the menu:

```applescript
tell application "System Events" to tell process "Simulator"
    set frontmost to true
    click menu item 1 of menu "visionOS 26.5" of menu item "visionOS 26.5" of ¬
        menu "Open Simulator" of menu item "Open Simulator" of ¬
        menu "File" of menu bar item "File" of menu bar 1
end tell
```

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
SIMID=$(scripts/worktree-sim.sh id)
xcrun simctl io "$SIMID" screenshot /tmp/visionplay-test.png   # then Read it
xcrun simctl spawn "$SIMID" log show --last 5m --predicate 'process == "VisionPlay"'
```

After a click, sleep ~2s before screenshotting (navigation/animation settles). If a click
seems to no-op: re-check Simulator was frontmost, then re-derive coords from a fresh crop —
those two cover every miss seen so far.

## Player chrome (auto-hide)

The player's chrome + info-tab strip auto-hide after ~5s. Chain the reveal-tap and the
target click in ONE Bash command so the chrome is still up:

```sh
osascript -e 'tell application "Simulator" to activate'; sleep 0.4
/tmp/simclick 865 588    # tap video center → chrome appears
sleep 1
/tmp/simclick <X> <Y>    # the actual target (tab pill, transport control…)
```

At window frame (10, 51, 1708×1013) with the expanded player, the info-tab pills sit at
screen y≈758: Info≈578, Quality≈635, Subtitles≈703, Audio≈769, Speed≈828, Stats≈886.
(Chapters only appears when the item has chapter markers.) Re-derive if the window moved.

## Standard loop

1. Build + install + relaunch (commands in CLAUDE.md).
2. Screenshot → Read → pick target → map coords (crop to refine if small).
3. Activate Simulator → `/tmp/simclick X Y` → sleep 2 → screenshot → verify.
4. For speculative fixes, add NSLog first (`NSLog("%@", str)` — never raw `%`) and read
   the log after exercising the path.
