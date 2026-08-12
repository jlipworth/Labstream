---
name: sim-driving
description: Run bounded visionOS simulator evidence scenarios and know when Xcode 27 requires a human or headset gate.
---

# Driving the visionOS simulator

> **STATUS on Xcode 27: passive harness only for visionOS.** Free-form synthetic clicking
> is not allowed: it caused misses/swallowed clicks and mouse takeover. The bounded click
> scenario also still addresses the retired standalone Simulator app and has not been proven
> against Device Hub, so do not invoke it on Xcode 27. Official Xcode Device Interaction is
> currently an iOS Simulator path, not a visionOS path. Use the passive harness and app-side
> probes for visionOS; ask for human/headset confirmation when they cannot prove the result.

If a future Device Hub-compatible click path is added, it must first re-prove the bounded loop:
screenshot/crop → locate target → synthetic click → screenshot/logs to verify. Hand off to the
user for auth setup, gaze-hover effects (a real cursor hover ≠ gaze highlight rendering in all
cases), pinch-drag gestures, or any flow where the harness cannot prove the UI changed.

## Repo scenario harness

Prefer the bounded harness over ad hoc clicks:

```sh
scripts/agent-sim-run.sh launch-fixture-home-passive
```

The harness resolves the worktree simulator via `scripts/worktree-sim.sh id`, records
artifacts under `artifacts/agent-sim-runs/`, and shuts the simulator down unless
`--keep-booted` is passed. Use scenario artifacts for issue comments and debugging notes.

`click-login-jellyfin-tab` is retained as legacy evidence, not as an Xcode 27-supported scenario.

## Legacy click helper (do not use on Xcode 27)

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

The device can stay booted with its window closed (`window 1 … Invalid index`). First try
`open -a Simulator` plus activation, as the harness does. If that still does not expose a
window, reopen via the menu:

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
xcrun simctl io "$SIMID" screenshot /tmp/labstream-test.png   # then Read it
xcrun simctl spawn "$SIMID" log show --last 5m --predicate 'process == "Labstream"'
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
