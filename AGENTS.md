# VisionPlay — agent notes (Codex)

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
script. The dev build shares the bundle id `com.jlipworth.VisionPlay` with the App Store
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
app-container listings, known VisionPlay diagnostic files when present, and
`VisionPlay/Downloads/index.json` when available. Treat the bundle as private; redact
device IDs, server details, media names, item IDs, tokens, and playSession IDs before any
public GitHub text.

Detailed agent instructions are mirrored for both assistants:

- Claude: `.claude/skills/headset-evidence/SKILL.md`
- Codex: `.codex/skills/headset-evidence/SKILL.md`

If `summary.json` reports `developer_disk_image_mount_unauthorized`, check VPN/network
filtering first; this can prevent `devicectl` from mounting the xrOS developer disk image.

## Worktree simulators

Each git worktree gets its own visionOS simulator so parallel worktrees don't clobber
each other's app container / login. `scripts/worktree-sim.sh` is the single source of
truth (also invoked by a `post-checkout` git hook).

- The **main** worktree owns the *golden* logged-in sim (`D9BD8E9D…`, in `<main>/.simid`).
  Never delete it.
- A **linked** worktree gets a `vpwt-<branch>` clone of the golden, created **shut down**;
  its UDID lives in `<worktree>/.simid` (git-ignored). Boot it yourself before building.
- Target `"$SIMID"` (from `scripts/worktree-sim.sh id`), never `booted` — `booted` errors
  once more than one sim is up.

```sh
scripts/worktree-sim.sh install-hook   # one-time: auto-clone on `git worktree add`
scripts/worktree-sim.sh setup          # provision this worktree's sim (idempotent)
scripts/worktree-sim.sh teardown       # delete this worktree's clone + .simid
scripts/worktree-sim.sh closeout PATH  # teardown PATH if present, then prune orphans
scripts/worktree-sim.sh prune          # sweep clones whose worktree is gone
SIMID=$(scripts/worktree-sim.sh id)    # this worktree's UDID for build/install/log
```

**Rule:** after creating a worktree run `setup`; when finishing/removing one run
`teardown` **before** `git worktree remove`, or run `closeout PATH` / `prune` immediately
afterward. `setup` clones from the golden sim, which `simctl` can only do while the
golden is shut down, so it briefly bounces a booted main sim (~10s blip).

### Worktree closeout checklist

Never call worktree cleanup done until the matching simulator is gone. Preferred flow:

```sh
# Before removing a linked worktree:
cd <worktree>
scripts/worktree-sim.sh teardown
cd <main>
git worktree remove <worktree>
git branch -D <branch>

# Safer one-command helper from any repo worktree:
scripts/worktree-sim.sh closeout <worktree>

# If the worktree was already removed or you are unsure:
scripts/worktree-sim.sh prune
xcrun simctl list devices | rg 'vpwt|<branch-fragment>' || true
```

Do not delete the golden main-worktree simulator. Only `vpwt-*` linked-worktree clones
should disappear during closeout.
