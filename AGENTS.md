# Labstream — agent notes (Codex)

Project-specific guidance also lives in `CLAUDE.md`; read it for the full build/test
loop and hard constraints. This file mirrors the points that matter most for Codex.

## Deploy to a physical Apple Vision Pro

On-device install (over Wi-Fi, via `devicectl`) is wrapped in one script — use it instead
of re-deriving the device signing, which has a recurring trap: the `DEVELOPMENT_TEAM` is
the signing cert's **OU** (`XXXXXXXXXX`), NOT the parenthetical in its name (`YYYYYYYYYY`).

```sh
scripts/deploy-to-device.sh            # build (signed) + install to the paired Vision Pro
scripts/deploy-to-device.sh --launch   # also launch (headset must be awake/worn)
scripts/deploy-to-device.sh --no-build # reinstall last build without rebuilding
```

One-time GUI prereqs (an agent can't do these): pair the headset, and sign an Apple ID
into Xcode ▸ Settings ▸ Accounts (a keychain cert alone is not enough → "No Account for
Team" build failure). Free-team provisioning profiles expire ~7 days — just re-run the
script. The dev build shares the bundle id `com.jlipworth.Labstream` with the App Store
build, so only one is installed at a time (the dev install clobbers App Store state).
Full detail + traps: `.claude/skills/deploy-to-device/SKILL.md`.


## Headset evidence after a physical repro

When the user has just reproduced a bug while wearing the headset, collect evidence before
trying ad hoc unified-log/sysdiagnose commands:

```sh
scripts/headset-evidence.sh
```

This is read-only: it does not install, launch, delete, or mutate the headset. It writes a
local bundle under `build/headset-evidence/` with `devicectl` JSON/log artifacts, bounded
app-container listings, known Labstream diagnostic files when present, and the legacy
`Labstream/Downloads/index.json` app-support path when available. Treat the bundle as private; redact
device IDs, server details, media names, item IDs, tokens, and playSession IDs before any
public GitHub text.

Detailed agent instructions are mirrored for both assistants:

- Claude: `.claude/skills/headset-evidence/SKILL.md`
- Codex: `.codex/skills/headset-evidence/SKILL.md`

If `summary.json` reports `developer_disk_image_mount_unauthorized`, check VPN/network
filtering first; this can prevent `devicectl` from mounting the xrOS developer disk image.

## Deploy to a physical iPhone or iPad

Use the mobile device wrapper for `LabstreamMobile` hardware installs. It builds a signed
`iphoneos` Debug app and installs with `devicectl`; simulator builds with
`CODE_SIGNING_ALLOWED=NO` will not install on hardware.

```sh
scripts/deploy-mobile-to-device.sh            # build + install to one paired iPhone/iPad
scripts/deploy-mobile-to-device.sh --launch   # also launch
IOS_DEVICE_ID=<uuid> scripts/deploy-mobile-to-device.sh --launch  # when multiple devices are paired
```

One-time GUI prereqs still apply: connect/pair the iPhone/iPad, trust this Mac, enable
Developer Mode if prompted, and sign the matching Apple ID into Xcode Settings ▸ Accounts
so command-line automatic provisioning can create profiles.

## Worktree simulators

Each git worktree gets its own simulator so parallel worktrees don't clobber each other's
app container / login. `scripts/worktree-sim.sh` is the single source of truth (also
invoked by a `post-checkout` git hook).

- The **main** worktree owns the visionOS *golden* logged-in sim (recorded in
  `<main>/.simid`). Never delete it.
- By default, a **linked** worktree gets a `vpwt-<branch>-<hash>` visionOS clone of the
  golden, created **shut down**; its UDID lives in `<worktree>/.simid` (git-ignored).
- iPhone/iPadOS work can opt into independent iOS simulators without touching the golden:
  use `LABSTREAM_SIM_PLATFORM=iphone` or `ipad`, `scripts/worktree-sim.sh --platform iphone|ipad ...`, or a
  gitignored `<worktree>/.simplatform` containing `iphone` or `ipad`. iPhone UDIDs live in
  `<worktree>/.simid-iphone`; iPad UDIDs live in `<worktree>/.simid-ipad`.
- Target `"$SIMID"` (from `scripts/worktree-sim.sh id`), never `booted` — `booted` errors
  once more than one sim is up.

```sh
scripts/worktree-sim.sh install-hook   # one-time: auto-clone on `git worktree add`
scripts/worktree-sim.sh setup          # provision this worktree's sim (idempotent)
scripts/worktree-sim.sh teardown       # delete this worktree's clone + .simid
scripts/worktree-sim.sh teardown --all # delete all sims owned by this linked worktree
scripts/worktree-sim.sh closeout PATH  # teardown PATH if present, then prune orphans
scripts/worktree-sim.sh prune          # sweep clones whose worktree is gone
SIMID=$(scripts/worktree-sim.sh id)    # this worktree's UDID for build/install/log
SIMID=$(scripts/worktree-sim.sh --platform visionos id) # force the visionOS sim
SIMID=$(scripts/worktree-sim.sh --platform iphone id)   # force the iPhone sim
SIMID=$(scripts/worktree-sim.sh --platform ipad id)     # force the iPad sim
```

If `install-hook` warns that `core.hooksPath` is set, Git will ignore the shared hook it
just wrote; unset that config before relying on auto-clone behavior.

**Rule:** after creating a worktree run `setup`; when finishing/removing one, prefer
`scripts/worktree-sim.sh closeout PATH` from any repo worktree, or run
`scripts/worktree-sim.sh teardown --all` inside the linked worktree **before**
`git worktree remove`. Use `prune` immediately afterward if removal already happened.
visionOS `setup` clones from the golden sim, which `simctl` can only do while the golden
is shut down, so it briefly bounces a booted main sim (~10s blip). iPhone/iPad setup
creates a fresh `iphonewt-*` or `ipadwt-*` simulator from the newest available iOS runtime instead.

### Worktree closeout checklist

Never call worktree cleanup done until the matching simulator is gone. Preferred flow:

```sh
# Before removing a linked worktree that may own both visionOS and iPad simulators:
cd <worktree>
scripts/worktree-sim.sh teardown --all
cd <main>
git worktree remove <worktree>
git branch -D <branch>

# Preferred one-command helper from any repo worktree:
scripts/worktree-sim.sh closeout <worktree>

# If the worktree was already removed or you are unsure:
scripts/worktree-sim.sh prune
xcrun simctl list devices | rg 'vpwt|iphonewt|ipadwt|<branch-fragment>' || true
```

Do not delete the golden main-worktree simulator. Only this linked worktree's `vpwt-*`,
`iphonewt-*`, and/or `ipadwt-*` simulators should disappear during closeout.
