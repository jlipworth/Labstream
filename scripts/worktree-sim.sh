#!/usr/bin/env bash
#
# worktree-sim.sh — give each git worktree its own visionOS simulator.
#
# The MAIN worktree owns a "golden" logged-in sim (its UDID lives in <main>/.simid).
# Each LINKED worktree gets a clone of that golden sim, named vpwt-<branch>-<hash>,
# created SHUT DOWN. The clone's UDID is written to <worktree>/.simid (git-ignored). The
# worktree's own agent boots/manipulates the sim as needed.
#
# Subcommands:
#   setup         clone the golden sim for the current (linked) worktree; idempotent.
#                 No-op in the main worktree or when a live .simid already exists.
#   teardown      delete the current worktree's vpwt-* sim and remove .simid.
#   closeout      safe finish command: teardown an existing linked worktree path, then
#                 prune orphaned vpwt-* sims. Use this before/after worktree removal.
#   prune         delete every vpwt-* sim no live worktree references (backstop for
#                 `git worktree remove`, which has no git hook).
#   id            print the current worktree's sim UDID (seeds/setups if needed).
#   install-hook  install a post-checkout hook (shared across worktrees) that runs
#                 `setup` after `git worktree add`.
#
set -euo pipefail

NAME_PREFIX="vpwt-"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

die() { echo "worktree-sim: $*" >&2; exit 1; }

worktree_root() { git rev-parse --show-toplevel; }

# First entry of `git worktree list` is always the main worktree.
main_worktree() { git worktree list --porcelain | awk '/^worktree /{print $2; exit}'; }

is_main() { [ "$(worktree_root)" = "$(main_worktree)" ]; }

# Golden UDID = main worktree's .simid. The file is local/gitignored because simulator IDs are
# machine-specific and should not be committed.
golden_udid() {
  local f; f="$(main_worktree)/.simid"
  if [ ! -f "$f" ]; then die "missing golden simulator id at $f; create it with this worktree's logged-in simulator UDID"; fi
  cat "$f"
}

hash_short() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -c1-8
  else
    shasum -a 256 | cut -c1-8
  fi
}

sim_name() {
  local b root h
  b=$(git symbolic-ref --short -q HEAD || git rev-parse --short HEAD)
  root=$(worktree_root)
  h=$(printf '%s\n%s' "$root" "$b" | hash_short)
  b=$(printf '%s' "$b" | sed 's#[^A-Za-z0-9_-]#-#g')
  b=${b:0:40}
  printf '%s%s-%s' "$NAME_PREFIX" "$b" "$h"
}

# Print the UDID of the first sim with the given exact name (empty if none).
sim_udid_by_name() {
  xcrun simctl list devices -j | python3 -c '
import json, sys
name = sys.argv[1]
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["name"] == name:
            print(d["udid"]); sys.exit(0)
' "$1"
}

# Print the name of the sim with the given UDID (empty if none).
sim_name_by_udid() {
  xcrun simctl list devices -j | python3 -c '
import json, sys
udid = sys.argv[1]
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["udid"] == udid:
            print(d["name"]); sys.exit(0)
' "$1"
}

sim_exists() { [ -n "$(sim_name_by_udid "$1")" ]; }

# Print the runtime state (Booted/Shutdown/...) of the sim with the given UDID.
sim_state_by_udid() {
  xcrun simctl list devices -j | python3 -c '
import json, sys
udid = sys.argv[1]
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["udid"] == udid:
            print(d["state"]); sys.exit(0)
' "$1"
}

# Clone the golden sim. `simctl clone` requires the SOURCE to be shut down, so if the
# golden is booted we briefly bounce it (login state is on disk and survives) and
# guarantee it is rebooted afterwards. Prints the new clone's UDID.
clone_golden() {
  local name="$1" golden gstate udid
  golden=$(golden_udid); gstate=$(sim_state_by_udid "$golden")
  if [ "$gstate" = "Booted" ]; then
    echo "worktree-sim: golden sim is booted — bouncing it (~10s) to clone; it will reboot, login survives." >&2
    xcrun simctl shutdown "$golden"
  fi
  if ! udid=$(xcrun simctl clone "$golden" "$name"); then
    [ "$gstate" = "Booted" ] && xcrun simctl boot "$golden" || true
    die "clone of golden ($golden) failed"
  fi
  [ "$gstate" = "Booted" ] && xcrun simctl boot "$golden" || true
  printf '%s' "$udid"
}

cmd_setup() {
  if is_main; then golden_udid >/dev/null; return 0; fi
  local root simid_file; root=$(worktree_root); simid_file="$root/.simid"
  if [ -f "$simid_file" ] && sim_exists "$(cat "$simid_file")"; then return 0; fi
  local name udid; name=$(sim_name)
  udid=$(sim_udid_by_name "$name")          # reuse if a matching sim already exists
  if [ -z "$udid" ]; then
    udid=$(clone_golden "$name")
  fi
  printf '%s\n' "$udid" > "$simid_file"
  echo "worktree-sim: $name -> $udid (shutdown)"
}

cmd_teardown() {
  local root simid_file; root=$(worktree_root); simid_file="$root/.simid"
  [ -f "$simid_file" ] || { echo "worktree-sim: no .simid here, nothing to tear down"; return 0; }
  local udid; udid=$(cat "$simid_file")
  [ "$udid" = "$(golden_udid)" ] && die "refusing to delete the golden sim ($udid)"
  local name; name=$(sim_name_by_udid "$udid")
  case "$name" in
    "${NAME_PREFIX}"*)
      xcrun simctl shutdown "$udid" 2>/dev/null || true
      xcrun simctl delete "$udid"
      echo "worktree-sim: deleted $name ($udid)"
      ;;
    "") echo "worktree-sim: sim $udid no longer exists" ;;
    *)  echo "worktree-sim: $udid ($name) is not a ${NAME_PREFIX}* sim, leaving it" ;;
  esac
  rm -f "$simid_file"
}

cmd_prune() {
  local refs="" wt tmp count
  while read -r wt; do
    if [ -f "$wt/.simid" ]; then refs+="$(cat "$wt/.simid") "; fi
  done < <(git worktree list --porcelain | awk '/^worktree /{print $2}')
  tmp=$(mktemp "${TMPDIR:-/tmp}/worktree-sim-prune.XXXXXX")
  xcrun simctl list devices -j | python3 -c '
import json, sys
prefix = sys.argv[1]
refs = set(sys.argv[2].split())
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["name"].startswith(prefix) and d["udid"] not in refs:
            print(d["udid"], d["name"])
' "$NAME_PREFIX" "$refs" > "$tmp"
  count=$(wc -l < "$tmp" | tr -d ' ')
  if [ "$count" = "0" ]; then
    echo "worktree-sim: no orphaned ${NAME_PREFIX}* simulators found"
    rm -f "$tmp"
    return 0
  fi
  while read -r udid name; do
    xcrun simctl shutdown "$udid" 2>/dev/null || true
    xcrun simctl delete "$udid"
    echo "worktree-sim: pruned $name ($udid)"
  done < "$tmp"
  rm -f "$tmp"
}

cmd_closeout() {
  local target="${1:-}" root main
  if [ -z "$target" ]; then
    target=$(worktree_root)
  fi

  if [ -d "$target" ] && git -C "$target" rev-parse --show-toplevel >/dev/null 2>&1; then
    root=$(git -C "$target" rev-parse --show-toplevel)
    main=$(git -C "$target" worktree list --porcelain | awk '/^worktree /{print $2; exit}')
    if [ "$root" = "$main" ]; then
      echo "worktree-sim: closeout target is the main worktree; not tearing down golden sim"
    else
      echo "worktree-sim: closeout tearing down simulator for $root"
      (cd "$root" && "$SCRIPT_PATH" teardown)
    fi
  else
    echo "worktree-sim: closeout target missing or not a git worktree; running prune backstop"
  fi

  cmd_prune
}

cmd_id() {
  if is_main; then golden_udid; return 0; fi
  local root simid_file udid; root=$(worktree_root); simid_file="$root/.simid"
  if [ -f "$simid_file" ]; then
    udid=$(cat "$simid_file")
    if sim_exists "$udid"; then
      printf '%s\n' "$udid"
      return 0
    fi
    echo "worktree-sim: stale .simid ($udid); provisioning a live simulator" >&2
  fi
  cmd_setup >&2
  udid=$(cat "$simid_file")
  sim_exists "$udid" || die "setup wrote $udid, but that simulator does not exist"
  printf '%s\n' "$udid"
}

cmd_install_hook() {
  local common hookdir hook hp
  common=$(git rev-parse --git-common-dir); common=$(cd "$common" && pwd)
  hookdir="$common/hooks"; mkdir -p "$hookdir"; hook="$hookdir/post-checkout"
  # A core.hooksPath override makes git ignore $common/hooks entirely. Warn loudly so
  # the hook we install here is not silently dead (this repo shipped with a stale one).
  hp=$(git config --get core.hooksPath || true)
  if [ -n "$hp" ]; then
    echo "worktree-sim: WARNING core.hooksPath=$hp is set; git will NOT run $hook." >&2
    echo "             To enable the auto-clone hook, run: git config --unset core.hooksPath" >&2
  fi
  cat > "$hook" <<'HOOK'
#!/usr/bin/env bash
# Auto-provision a per-worktree simulator after `git worktree add`.
# post-checkout args: $1 prev-HEAD  $2 new-HEAD  $3 branch-checkout-flag (1 = branch).
[ "${3:-0}" = "1" ] || exit 0
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
script="$root/scripts/worktree-sim.sh"
[ -x "$script" ] && "$script" setup || true
HOOK
  chmod +x "$hook"
  echo "worktree-sim: installed $hook"
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    setup)        cmd_setup "$@" ;;
    teardown)     cmd_teardown "$@" ;;
    closeout)     cmd_closeout "$@" ;;
    prune)        cmd_prune "$@" ;;
    id)           cmd_id "$@" ;;
    install-hook) cmd_install_hook "$@" ;;
    *) die "usage: worktree-sim.sh {setup|teardown|closeout|prune|id|install-hook}" ;;
  esac
}

main "$@"
