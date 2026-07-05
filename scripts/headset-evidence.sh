#!/usr/bin/env bash
# Gather a best-effort local evidence bundle from a paired Apple Vision Pro.
#
# This is intentionally read-only: it does not install, launch, delete, or mutate
# anything on the headset. It favors devicectl JSON/log-output artifacts because
# that is the supported scripting interface and has been more reliable than
# host-side unified-log/sysdiagnose collection for Labstream headset repros.

set -u
set -o pipefail

BUNDLE_ID="com.jlipworth.VisionPlay"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_OUT_ROOT="$REPO/build/headset-evidence"
DEVICE_ID="${VP_DEVICE_ID:-}"
OUT_ROOT="${VP_HEADSET_EVIDENCE_OUT:-$DEFAULT_OUT_ROOT}"
TIMEOUT="${VP_DEVICECTL_TIMEOUT:-20}"
VERBOSE=0

usage() {
  cat <<USAGE
Usage: scripts/headset-evidence.sh [options]

Read-only headset evidence collection for Labstream after a user-driven repro.

Options:
  --device <id>       Target Vision Pro device UDID/name (default: VP_DEVICE_ID or first paired visionOS device)
  --out <path>        Output root or bundle path (default: build/headset-evidence/headset-evidence-<timestamp>)
  --bundle-id <id>    App bundle identifier (default: $BUNDLE_ID)
  --timeout <seconds> devicectl command timeout (default: $TIMEOUT)
  --verbose           Print full command stdout/stderr while running
  -h, --help          Show this help

The bundle may contain private local artifacts (device IDs, media filenames,
server-derived metadata). Do not paste raw bundle contents into public issues;
redact before sharing.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --device)
      [ "$#" -ge 2 ] || { echo "headset-evidence: --device requires a value" >&2; exit 2; }
      DEVICE_ID="$2"; shift 2 ;;
    --out)
      [ "$#" -ge 2 ] || { echo "headset-evidence: --out requires a value" >&2; exit 2; }
      OUT_ROOT="$2"; shift 2 ;;
    --bundle-id)
      [ "$#" -ge 2 ] || { echo "headset-evidence: --bundle-id requires a value" >&2; exit 2; }
      BUNDLE_ID="$2"; shift 2 ;;
    --timeout)
      [ "$#" -ge 2 ] || { echo "headset-evidence: --timeout requires a value" >&2; exit 2; }
      TIMEOUT="$2"; shift 2 ;;
    --verbose)
      VERBOSE=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "headset-evidence: unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

case "$TIMEOUT" in
  ''|*[!0-9]*) echo "headset-evidence: --timeout must be a positive integer" >&2; exit 2 ;;
esac

if ! command -v xcrun >/dev/null 2>&1; then
  echo "headset-evidence: xcrun is required" >&2
  exit 1
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
case "$(basename "$OUT_ROOT")" in
  headset-evidence-*) OUT="$OUT_ROOT" ;;
  *) OUT="$OUT_ROOT/headset-evidence-$TS" ;;
esac

COMMANDS_TSV="$OUT/command-results.tsv"
COPIED_TSV="$OUT/copied-files.tsv"
MISSES_TSV="$OUT/missing-files.tsv"
DEVLOG_DIR="$OUT/logs/devicectl"
FILES_DIR="$OUT/app-container-files"
mkdir -p "$OUT" "$DEVLOG_DIR" "$FILES_DIR"
: > "$COMMANDS_TSV"
: > "$COPIED_TSV"
: > "$MISSES_TSV"

log() { printf '%s\n' "$*"; }

record_command() {
  # status, label, argv, json_path, log_path
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$COMMANDS_TSV"
}

run_devicectl() {
  label="$1"; json_path="$2"; log_path="$3"; shift 3
  stdout_path="$log_path.stdout"
  stderr_path="$log_path.stderr"
  argv="xcrun devicectl $* --timeout $TIMEOUT --json-output $json_path --log-output $log_path"
  log "→ $label"
  if [ "$VERBOSE" -eq 1 ]; then
    xcrun devicectl "$@" --timeout "$TIMEOUT" --json-output "$json_path" --log-output "$log_path" \
      > >(tee "$stdout_path") 2> >(tee "$stderr_path" >&2)
    status=$?
  else
    xcrun devicectl "$@" --timeout "$TIMEOUT" --json-output "$json_path" --log-output "$log_path" \
      >"$stdout_path" 2>"$stderr_path"
    status=$?
  fi
  record_command "$status" "$label" "$argv" "$json_path" "$log_path"
  if [ "$status" -ne 0 ]; then
    log "  non-fatal: $label failed (status $status; see $log_path.stderr)"
  fi
  return 0
}

copy_from_app_container() {
  src="$1"
  dest_rel="$2"
  mkdir -p "$FILES_DIR/$(dirname "$dest_rel")"
  dest="$FILES_DIR/$dest_rel"
  safe_name="copy-$(printf '%s' "$dest_rel" | tr '/ :' '___')"
  json_path="$DEVLOG_DIR/$safe_name.json"
  log_path="$DEVLOG_DIR/$safe_name.log"
  stdout_path="$log_path.stdout"
  stderr_path="$log_path.stderr"
  argv="xcrun devicectl device copy from --device $DEVICE_ID --domain-type appDataContainer --domain-identifier $BUNDLE_ID --source $src --destination $dest --timeout $TIMEOUT --json-output $json_path --log-output $log_path"
  log "→ copy $src"
  xcrun devicectl device copy from \
    --device "$DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    --source "$src" \
    --destination "$dest" \
    --timeout "$TIMEOUT" \
    --json-output "$json_path" \
    --log-output "$log_path" \
    >"$stdout_path" 2>"$stderr_path"
  status=$?
  record_command "$status" "copy $src" "$argv" "$json_path" "$log_path"
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\n' "$src" "$dest" >> "$COPIED_TSV"
  else
    rm -rf "$dest"
    printf '%s\t%s\n' "$src" "$stderr_path" >> "$MISSES_TSV"
    log "  non-fatal: missing or inaccessible ($src)"
  fi
  return 0
}

# 1. Always capture device inventory first. This also gives us the supported JSON
#    source for auto-selecting the target Vision Pro.
run_devicectl "device list" "$OUT/devicectl-devices.json" "$DEVLOG_DIR/devicectl-devices.log" list devices --columns '*'

if [ -z "$DEVICE_ID" ]; then
  DEVICE_ID="$(python3 - "$OUT/devicectl-devices.json" <<'PY'
import json, sys
path = sys.argv[1]
try:
    devices = json.load(open(path)).get("result", {}).get("devices", [])
except Exception:
    devices = []

def text_blob(obj):
    try:
        return json.dumps(obj).lower()
    except Exception:
        return str(obj).lower()

candidates = []
for d in devices:
    blob = text_blob(d)
    if "vision" in blob or "reality" in blob or "xros" in blob:
        candidates.append(d)

for d in candidates:
    ident = d.get("identifier") or d.get("udid") or d.get("deviceIdentifier")
    if isinstance(ident, str) and ident:
        print(ident)
        break
PY
)"
fi

if [ -z "$DEVICE_ID" ]; then
  cat > "$OUT/README.md" <<README
# Labstream headset evidence bundle

Collection started at $TS UTC, but no Vision Pro device identifier could be selected.

See:
- devicectl-devices.json
- logs/devicectl/devicectl-devices.log*

Try again after confirming the headset is paired/available in Xcode, or pass an explicit device if the JSON inventory did not identify it as visionOS:

\`\`\`sh
VP_DEVICE_ID=<vision-pro-device-udid> scripts/headset-evidence.sh
# or
scripts/headset-evidence.sh --device <vision-pro-device-udid>
\`\`\`
README
  python3 - "$OUT" "$TS" "$BUNDLE_ID" "$COMMANDS_TSV" "$COPIED_TSV" "$MISSES_TSV" <<'PY'
import json, sys
out, ts, bundle, commands_tsv, copied_tsv, misses_tsv = sys.argv[1:]

def rows(path, fields):
    result=[]
    try:
        for line in open(path):
            parts=line.rstrip('\n').split('\t')
            result.append(dict(zip(fields, parts)))
    except FileNotFoundError:
        pass
    return result
summary={"created_at_utc": ts, "bundle_id": bundle, "device_selected": False,
         "commands": rows(commands_tsv, ["status","label","command","json_path","log_path"]),
         "copied_files": rows(copied_tsv, ["source","destination"]),
         "missing_files": rows(misses_tsv, ["source","stderr_path"])}
open(f"{out}/summary.json", "w").write(json.dumps(summary, indent=2) + "\n")
PY
  log "Bundle written: $OUT"
  exit 0
fi

log "device selected: $DEVICE_ID"

# 2. Process state and read-only file inventories.
run_devicectl "process info" "$OUT/process-info.json" "$DEVLOG_DIR/process-info.log" \
  device info processes --device "$DEVICE_ID" --columns '*'

run_devicectl "app container root listing" "$OUT/app-container-root.json" "$DEVLOG_DIR/app-container-root.log" \
  device info files --device "$DEVICE_ID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --columns '*' --no-recurse

run_devicectl "app support listing" "$OUT/app-container-application-support.json" "$DEVLOG_DIR/app-container-application-support.log" \
  device info files --device "$DEVICE_ID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --columns '*' --subdirectory 'Library/Application Support' --no-recurse

run_devicectl "Labstream support listing" "$OUT/app-container-labstream-support.json" "$DEVLOG_DIR/app-container-labstream-support.log" \
  device info files --device "$DEVICE_ID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --columns '*' --subdirectory 'Library/Application Support/VisionPlay' --no-recurse

run_devicectl "Labstream downloads listing" "$OUT/app-container-labstream-downloads.json" "$DEVLOG_DIR/app-container-labstream-downloads.log" \
  device info files --device "$DEVICE_ID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --columns '*' --subdirectory 'Library/Application Support/VisionPlay/Downloads' --no-recurse

run_devicectl "system crash log listing" "$OUT/system-crashlogs.json" "$DEVLOG_DIR/system-crashlogs.log" \
  device info files --device "$DEVICE_ID" --domain-type systemCrashLogs --columns '*' --no-recurse

# 3. Copy high-value, bounded app-owned files only. Avoid copying actual media.
copy_from_app_container 'Library/Application Support/VisionPlay/Downloads/index.json' 'Library/Application Support/VisionPlay/Downloads/index.json'
copy_from_app_container 'Library/Application Support/VisionPlay/Diagnostics' 'Library/Application Support/VisionPlay/Diagnostics'
copy_from_app_container 'Library/Application Support/Diagnostics' 'Library/Application Support/Diagnostics'
copy_from_app_container 'Documents/Labstream-Diagnostic-Report.txt' 'Documents/Labstream-Diagnostic-Report.txt'
copy_from_app_container 'Documents/Labstream-Feedback.txt' 'Documents/Labstream-Feedback.txt'
copy_from_app_container 'tmp/Labstream-Diagnostic-Report.txt' 'tmp/Labstream-Diagnostic-Report.txt'

cat > "$OUT/README.md" <<README
# Labstream headset evidence bundle

Created: $TS UTC
Bundle ID: $BUNDLE_ID
Device: recorded in summary.json and devicectl JSON artifacts

This is a local, potentially sensitive evidence pack. It may include device IDs,
file names, media-derived metadata, and app-container state. Do **not** paste raw
contents into public GitHub issues. Redact tokens, hostnames, media names, item
IDs, device IDs, and playSession IDs before sharing.

## What was collected

- \`devicectl-devices.json\`: CoreDevice device inventory.
- \`process-info.json\`: running process inventory from the headset.
- \`app-container-root.json\`: non-recursive app data container root listing.
- \`app-container-application-support.json\`: non-recursive Application Support listing.
- \`app-container-labstream-support.json\`: non-recursive Labstream support directory listing.
- \`app-container-labstream-downloads.json\`: non-recursive Downloads directory listing, where the download index usually lives.
- \`system-crashlogs.json\`: non-recursive crash-log domain listing only (no crash logs copied by default).
- \`app-container-files/\`: best-effort copies of bounded known app files, including \`Labstream/Downloads/index.json\` when present.
- \`logs/devicectl/\`: per-command devicectl logs/stdout/stderr.
- \`summary.json\`: command statuses, copied-file list, and misses.

## Suggested triage order

1. Read \`summary.json\` for failed commands, classified failures, and copied files.
2. If \`classified_failures\` contains \`developer_disk_image_mount_unauthorized\`, ask the human to wear/unlock/trust the headset and check Xcode Devices, then retry this script.
3. Inspect \`app-container-files/Library/Application Support/VisionPlay/Downloads/index.json\` if present.
4. Inspect any copied diagnostics report or diagnostics directory if present.
5. Use the app-container JSON listings to decide whether another bounded file should be copied manually.
6. Only then try heavier host unified-log/sysdiagnose paths; those may be unreliable for headset repros.
README

python3 - "$OUT" "$TS" "$BUNDLE_ID" "$DEVICE_ID" "$COMMANDS_TSV" "$COPIED_TSV" "$MISSES_TSV" <<'PY'
import json, os, sys
out, ts, bundle, device, commands_tsv, copied_tsv, misses_tsv = sys.argv[1:]

def rows(path, fields):
    result=[]
    try:
        for line in open(path, encoding="utf-8"):
            parts=line.rstrip("\n").split("\t")
            row=dict(zip(fields, parts))
            if "status" in row:
                try: row["status"] = int(row["status"])
                except Exception: pass
            result.append(row)
    except FileNotFoundError:
        pass
    return result

commands = rows(commands_tsv, ["status","label","command","json_path","log_path"])
copied = rows(copied_tsv, ["source","destination"])
missing = rows(misses_tsv, ["source","stderr_path"])

def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except Exception:
        return ""

def classify_failures(commands):
    findings = []
    saw_ddi_auth = False
    for command in commands:
        if command.get("status") == 0:
            continue
        stderr = read_text((command.get("log_path") or "") + ".stderr")
        if "CoreDeviceError error 12040" in stderr or "kAMDMobileImageMounterNetworkUnauthorizedError" in stderr or "kAMAuthInstallErrorHTTPUnauthorized" in stderr:
            saw_ddi_auth = True
    if saw_ddi_auth:
        findings.append({
            "code": "developer_disk_image_mount_unauthorized",
            "message": "devicectl could see the headset but could not mount the xrOS developer disk image; check VPN/network filtering first, then ask the human to wear/unlock/trust the headset and check Xcode Devices before retrying.",
        })
    return findings

classified_failures = classify_failures(commands)
summary = {
    "created_at_utc": ts,
    "bundle_id": bundle,
    "device_selected": True,
    "device": device,
    "out_dir": out,
    "command_count": len(commands),
    "failed_command_count": sum(1 for c in commands if c.get("status") != 0),
    "copied_file_count": len(copied),
    "missing_file_count": len(missing),
    "commands": commands,
    "copied_files": copied,
    "missing_files": missing,
    "classified_failures": classified_failures,
    "privacy_note": "Local bundle may contain private device IDs, media filenames, hostnames, tokens, item IDs, or playSession IDs. Redact before public sharing.",
}
with open(os.path.join(out, "summary.json"), "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2)
    f.write("\n")
PY

log "Bundle written: $OUT"
log "Summary: $OUT/summary.json"
