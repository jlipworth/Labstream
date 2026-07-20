#!/usr/bin/env bash
#
# worktree-sim.sh — give each git worktree its own simulator.
#
# Default behavior is unchanged for existing worktrees: visionOS uses the MAIN worktree's
# logged-in "golden" simulator (<main>/.simid) and LINKED worktrees get vpwt-* clones of
# that golden, created SHUT DOWN.
#
# iPhone/iPadOS/tvOS work can opt into an independent simulator instead of cloning the
# visionOS golden. Select it with either:
#   LABSTREAM_SIM_PLATFORM=iphone scripts/worktree-sim.sh id
#   scripts/worktree-sim.sh --platform iphone id
# or write `iphone` to a gitignored <worktree>/.simplatform. iPhone simulators are named
# iphonewt-<branch>-<hash> and recorded in <worktree>/.simid-iphone.
#
# iPad work is the same shape:
#   LABSTREAM_SIM_PLATFORM=ipad scripts/worktree-sim.sh id
#   scripts/worktree-sim.sh --platform ipad id
# or write `ipad` to a gitignored <worktree>/.simplatform. iPad simulators are named
# ipadwt-<branch>-<hash> and recorded in <worktree>/.simid-ipad.
#
# tvOS work uses the current supported Apple TV generation only:
#   LABSTREAM_SIM_PLATFORM=tvos scripts/worktree-sim.sh id
#   scripts/worktree-sim.sh --platform tvos id
# or write `tvos` to a gitignored <worktree>/.simplatform. Apple TV simulators are named
# tvwt-<branch>-<hash> and recorded in <worktree>/.simid-tvos.
#
# Subcommands:
#   setup         provision this worktree's sim; idempotent.
#                 visionOS: no-op in main or clone golden in linked worktrees.
#                 iPhone/iPadOS/tvOS: create/reuse a shutdown simulator for this worktree.
#   teardown      delete the current worktree's owned sim for the selected platform and
#                 remove its simid file. Use --all to delete every linked-worktree sim
#                 owned by this worktree (never the main golden sim).
#   closeout      safe finish command: teardown all sims for an existing linked worktree
#                 path, then prune orphaned worktree sims.
#   prune         delete every vpwt-* / ipadwt-* / iphonewt-* / tvwt-* sim no live worktree references.
#   id            print the current worktree's sim UDID (seeds/setups if needed).
#   platform      print the effective platform (visionos, iphone, ipad, or tvos).
#   install-hook  install a post-checkout hook that runs `setup` after `git worktree add`.
#
set -euo pipefail

VISION_PREFIX="vpwt-"
IPAD_PREFIX="ipadwt-"
IPHONE_PREFIX="iphonewt-"
TV_PREFIX="tvwt-"
DEFAULT_PLATFORM="visionos"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
PLATFORM_OVERRIDE=""

# These iPad device types are ordered newest/preferred first. If a local Xcode does not
# have one, setup falls back to the first available iPad device type reported by simctl.
IPAD_DEVICE_TYPE_CANDIDATES=(
  "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"
  "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-16GB"
  "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB"
  "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M4"
  "com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M4"
  "com.apple.CoreSimulator.SimDeviceType.iPad-A16"
)

# These iPhone device types are ordered newest/preferred first. If a local Xcode does not
# have one, setup falls back to the first available iPhone device type reported by simctl.
IPHONE_DEVICE_TYPE_CANDIDATES=(
  "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
  "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
  "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
  "com.apple.CoreSimulator.SimDeviceType.iPhone-16"
  "com.apple.CoreSimulator.SimDeviceType.iPhone-16e"
  "com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro"
  "com.apple.CoreSimulator.SimDeviceType.iPhone-15"
)

# Initial tvOS support is deliberately limited to the latest shipping Apple TV 4K
# generation. The 1080p simulator is the same hardware generation and remains a layout
# fallback; do not silently select an older Apple TV device type.
TV_DEVICE_TYPE_CANDIDATES=(
  "com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K"
  "com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-1080p"
)

die() { echo "worktree-sim: $*" >&2; exit 1; }
usage() { printf '%s\n' "usage: worktree-sim.sh [--platform visionos|iphone|ipad|tvos] {setup|teardown [--all]|closeout [PATH]|prune|id|platform|install-hook|-h|--help}"; }

worktree_root() { git rev-parse --show-toplevel; }

# First entry of `git worktree list` is always the main worktree.
main_worktree() { git worktree list --porcelain | awk '/^worktree /{print $2; exit}'; }

is_main() { [ "$(worktree_root)" = "$(main_worktree)" ]; }

normalize_platform() {
  local p="${1:-}"
  p=$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')
  case "$p" in
    ""|vision|visionos|xros|xr|vp) printf 'visionos' ;;
    ipad|ipados) printf 'ipad' ;;
    iphone|ios|mobile) printf 'iphone' ;;
    tv|tvos|appletv|apple-tv) printf 'tvos' ;;
    *) die "unknown simulator platform '$p' (expected visionos, iphone, ipad, or tvos)" ;;
  esac
}

effective_platform() {
  if [ -n "$PLATFORM_OVERRIDE" ]; then
    normalize_platform "$PLATFORM_OVERRIDE"
    return 0
  fi
  if [ -n "${LABSTREAM_SIM_PLATFORM:-}" ]; then
    normalize_platform "$LABSTREAM_SIM_PLATFORM"
    return 0
  fi
  local f
  f="$(worktree_root)/.simplatform"
  if [ -f "$f" ]; then
    normalize_platform "$(tr -d '[:space:]' < "$f")"
    return 0
  fi
  printf '%s' "$DEFAULT_PLATFORM"
}

name_prefix_for_platform() {
  case "$(normalize_platform "$1")" in
    visionos) printf '%s' "$VISION_PREFIX" ;;
    ipad) printf '%s' "$IPAD_PREFIX" ;;
    iphone) printf '%s' "$IPHONE_PREFIX" ;;
    tvos) printf '%s' "$TV_PREFIX" ;;
  esac
}

simid_file_for_platform() {
  local root platform
  root=$(worktree_root)
  platform=$(normalize_platform "$1")
  case "$platform" in
    visionos) printf '%s/.simid' "$root" ;;
    ipad) printf '%s/.simid-ipad' "$root" ;;
    iphone) printf '%s/.simid-iphone' "$root" ;;
    tvos) printf '%s/.simid-tvos' "$root" ;;
  esac
}

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
  local platform prefix b root h
  platform=$(normalize_platform "$1")
  prefix=$(name_prefix_for_platform "$platform")
  b=$(git symbolic-ref --short -q HEAD || git rev-parse --short HEAD)
  root=$(worktree_root)
  h=$(printf '%s\n%s\n%s' "$root" "$b" "$platform" | hash_short)
  b=$(printf '%s' "$b" | sed 's#[^A-Za-z0-9_-]#-#g')
  b=${b:0:40}
  printf '%s%s-%s' "$prefix" "$b" "$h"
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

available_ios_runtime() {
  xcrun simctl list runtimes -j | python3 -c '
import json, re, sys
runtimes = json.load(sys.stdin).get("runtimes", [])
def version_tuple(r):
    text = r.get("version") or r.get("name", "")
    nums = [int(x) for x in re.findall(r"\d+", text)]
    return tuple(nums)
choices = [r for r in runtimes
           if r.get("isAvailable", True)
           and ".SimRuntime.iOS-" in r.get("identifier", "")]
choices.sort(key=version_tuple, reverse=True)
if choices:
    print(choices[0]["identifier"])
'
}

available_tvos_runtime() {
  xcrun simctl list runtimes -j | python3 -c '
import json, re, sys
runtimes = json.load(sys.stdin).get("runtimes", [])
def version_tuple(r):
    text = r.get("version") or r.get("name", "")
    return tuple(int(x) for x in re.findall(r"\d+", text))
choices = [r for r in runtimes
           if r.get("isAvailable", True)
           and ".SimRuntime.tvOS-" in r.get("identifier", "")]
choices.sort(key=version_tuple, reverse=True)
if choices:
    print(choices[0]["identifier"])
'
}

available_tvos_device_type() {
  local candidate
  for candidate in "${TV_DEVICE_TYPE_CANDIDATES[@]}"; do
    if xcrun simctl list devicetypes -j | python3 -c 'import json,sys; target=sys.argv[1]; print(any(d.get("identifier")==target and d.get("isAvailable", True) for d in json.load(sys.stdin).get("devicetypes", [])))' "$candidate" | grep -q True; then
      printf '%s' "$candidate"
      return 0
    fi
  done
}

available_device_type() {
  local family="$1"
  local candidate
  local -a candidates=()
  case "$family" in
    ipad) candidates=("${IPAD_DEVICE_TYPE_CANDIDATES[@]}") ;;
    iphone) candidates=("${IPHONE_DEVICE_TYPE_CANDIDATES[@]}") ;;
    *) die "unknown iOS device family '$family'" ;;
  esac
  for candidate in "${candidates[@]}"; do
    if xcrun simctl list devicetypes -j | python3 -c 'import json,sys; target=sys.argv[1]; print(any(d.get("identifier")==target and d.get("isAvailable", True) for d in json.load(sys.stdin).get("devicetypes", [])))' "$candidate" | grep -q True; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  xcrun simctl list devicetypes -j | python3 -c '
import json, sys
family = sys.argv[1]
needle = "iPad" if family == "ipad" else "iPhone"
ident_needle = f"SimDeviceType.{needle}"
for d in json.load(sys.stdin).get("devicetypes", []):
    ident = d.get("identifier", "")
    name = d.get("name", "")
    if d.get("isAvailable", True) and needle in name and ident_needle in ident:
        print(ident); sys.exit(0)
' "$family"
}

create_ios_sim() {
  local family="$1" name="$2" runtime device udid label
  runtime=$(available_ios_runtime)
  [ -n "$runtime" ] || die "no available iOS simulator runtime found"
  device=$(available_device_type "$family")
  label=$([ "$family" = "ipad" ] && printf 'iPad' || printf 'iPhone')
  [ -n "$device" ] || die "no available ${label} simulator device type found"
  udid=$(xcrun simctl create "$name" "$device" "$runtime") || die "create ${label} simulator failed"
  printf '%s' "$udid"
}

create_tvos_sim() {
  local name="$1" runtime device udid
  runtime=$(available_tvos_runtime)
  [ -n "$runtime" ] || die "no available tvOS simulator runtime found"
  device=$(available_tvos_device_type)
  [ -n "$device" ] || die "no supported Apple TV 4K (3rd generation) simulator device type found"
  udid=$(xcrun simctl create "$name" "$device" "$runtime") || die "create Apple TV simulator failed"
  printf '%s' "$udid"
}

cmd_setup_platform() {
  local platform root simid_file name udid
  platform=$(normalize_platform "$1")
  root=$(worktree_root)
  simid_file=$(simid_file_for_platform "$platform")

  if [ "$platform" = "visionos" ] && is_main; then
    golden_udid >/dev/null
    return 0
  fi

  if [ -f "$simid_file" ] && sim_exists "$(cat "$simid_file")"; then return 0; fi
  name=$(sim_name "$platform")
  udid=$(sim_udid_by_name "$name")          # reuse if a matching sim already exists
  if [ -z "$udid" ]; then
    case "$platform" in
      visionos) udid=$(clone_golden "$name") ;;
      ipad) udid=$(create_ios_sim ipad "$name") ;;
      iphone) udid=$(create_ios_sim iphone "$name") ;;
      tvos) udid=$(create_tvos_sim "$name") ;;
    esac
  fi
  printf '%s\n' "$udid" > "$simid_file"
  echo "worktree-sim: $name -> $udid (shutdown)"
}

cmd_setup() { cmd_setup_platform "$(effective_platform)"; }

cmd_teardown_platform() {
  local platform root simid_file udid name prefix
  platform=$(normalize_platform "$1")
  root=$(worktree_root); simid_file=$(simid_file_for_platform "$platform")
  [ -f "$simid_file" ] || { echo "worktree-sim: no $(basename "$simid_file") here, nothing to tear down"; return 0; }
  udid=$(cat "$simid_file")
  if [ "$platform" = "visionos" ] && [ "$udid" = "$(golden_udid)" ]; then
    die "refusing to delete the golden sim ($udid)"
  fi
  prefix=$(name_prefix_for_platform "$platform")
  name=$(sim_name_by_udid "$udid")
  case "$name" in
    "${prefix}"*)
      xcrun simctl shutdown "$udid" 2>/dev/null || true
      xcrun simctl delete "$udid"
      echo "worktree-sim: deleted $name ($udid)"
      ;;
    "") echo "worktree-sim: sim $udid no longer exists" ;;
    *)  echo "worktree-sim: $udid ($name) is not a ${prefix}* sim, leaving it" ;;
  esac
  rm -f "$simid_file"
}

cmd_teardown() {
  if [ "${1:-}" = "--all" ]; then
    cmd_teardown_platform visionos
    cmd_teardown_platform ipad
    cmd_teardown_platform iphone
    cmd_teardown_platform tvos
    return 0
  fi
  cmd_teardown_platform "$(effective_platform)"
}

cmd_prune() {
  local refs="" wt tmp count
  while read -r wt; do
    if [ -f "$wt/.simid" ]; then refs+="$(cat "$wt/.simid") "; fi
    if [ -f "$wt/.simid-ipad" ]; then refs+="$(cat "$wt/.simid-ipad") "; fi
    if [ -f "$wt/.simid-iphone" ]; then refs+="$(cat "$wt/.simid-iphone") "; fi
    if [ -f "$wt/.simid-tvos" ]; then refs+="$(cat "$wt/.simid-tvos") "; fi
  done < <(git worktree list --porcelain | awk '/^worktree /{print $2}')
  tmp=$(mktemp "${TMPDIR:-/tmp}/worktree-sim-prune.XXXXXX")
  xcrun simctl list devices -j | python3 -c '
import json, sys
prefixes = tuple(sys.argv[1].split(","))
refs = set(sys.argv[2].split())
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["name"].startswith(prefixes) and d["udid"] not in refs:
            print(d["udid"], d["name"])
' "$VISION_PREFIX,$IPAD_PREFIX,$IPHONE_PREFIX,$TV_PREFIX" "$refs" > "$tmp"
  count=$(wc -l < "$tmp" | tr -d ' ')
  if [ "$count" = "0" ]; then
    echo "worktree-sim: no orphaned ${VISION_PREFIX}* / ${IPAD_PREFIX}* / ${IPHONE_PREFIX}* / ${TV_PREFIX}* simulators found"
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
      echo "worktree-sim: closeout tearing down simulators for $root"
      (cd "$root" && "$SCRIPT_PATH" teardown --all)
    fi
  else
    echo "worktree-sim: closeout target missing or not a git worktree; running prune backstop"
  fi

  cmd_prune
}

cmd_id() {
  local platform root simid_file udid
  platform=$(effective_platform)
  if [ "$platform" = "visionos" ] && is_main; then golden_udid; return 0; fi
  root=$(worktree_root); simid_file=$(simid_file_for_platform "$platform")
  if [ -f "$simid_file" ]; then
    udid=$(cat "$simid_file")
    if sim_exists "$udid"; then
      printf '%s\n' "$udid"
      return 0
    fi
    echo "worktree-sim: stale $(basename "$simid_file") ($udid); provisioning a live simulator" >&2
  fi
  cmd_setup_platform "$platform" >&2
  udid=$(cat "$simid_file")
  sim_exists "$udid" || die "setup wrote $udid, but that simulator does not exist"
  printf '%s\n' "$udid"
}

cmd_platform() { effective_platform; printf '\n'; }

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
  while [ "${1:-}" = "--platform" ]; do
    shift
    [ -n "${1:-}" ] || die "missing value for --platform"
    PLATFORM_OVERRIDE="$1"
    shift
  done

  local cmd="${1:-}"; shift || true
  case "$cmd" in
    setup)        cmd_setup "$@" ;;
    teardown)     cmd_teardown "$@" ;;
    closeout)     cmd_closeout "$@" ;;
    prune)        cmd_prune "$@" ;;
    id)           cmd_id "$@" ;;
    platform)     cmd_platform "$@" ;;
    install-hook) cmd_install_hook "$@" ;;
    -h|--help)    usage ;;
    *) die "$(usage)" ;;
  esac
}

main "$@"
