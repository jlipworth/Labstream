#!/usr/bin/env bash
# Parse (SANY) and model-check (TLC) every TLA+ spec/config pair under specs/.
#
# Usage:
#   scripts/check-tla-specs.sh                 # every module and every .cfg under specs/
#   scripts/check-tla-specs.sh PATH...         # only these .cfg/.tla files or folders (searched
#                                              # recursively: a module folder, an area, specs/)
#   scripts/check-tla-specs.sh --deep          # also run the configs tagged `TIER: deep`
#   scripts/check-tla-specs.sh --deep-only     # run only the deep configs
#   scripts/check-tla-specs.sh --list          # print the configs that would run
#
# Each TLC run is a `<Name>.cfg` file. Its first lines declare the run:
#   \* SPEC: DownloadsSessionCore            (module to check; default: the .cfg basename)
#   \* EXPECT: pass                          (default)
#   \* EXPECT: violation FinishedBodyNotLost (TLC must report exactly this invariant or action
#                                             property violated)
#   \* EXPECT: violation DEADLOCK
#   \* EXPECT: violation TEMPORAL            (the config's one PROPERTY fails as a liveness check)
#   \* EXPECT: violation TEMPORAL Settles    (required when the config lists several properties)
#   \* TIER: deep                            (default: default)
# An "EXPECT: violation" config is a faithfulness or known-finding check: the run fails when TLC
# passes, or when it reports a different property. Counterexamples are always printed.
# TLC reports a failed liveness property only as "Temporal properties were violated", without the
# name. So a config with several properties must name the one that fails, and the script then
# runs TLC twice from copies of the config: once with only that property (it must be violated)
# and once with the others (they must hold). An unnamed TEMPORAL expectation over several
# properties is a failure, not a guess.
# A result counts only when TLC's exit status, its banner and a clean finish agree (see
# classify_tlc): a crash, an out-of-memory error, a killed JVM, an evaluation error or a
# truncated log fails the config whatever was printed first, for every kind of EXPECT.
# A deep config is skipped unless --deep, --deep-only or TLC_TIER asks for it, or the .cfg file
# itself is named on the command line. Every module is parsed whatever the tier.
#
# Layout: specs/<area>/<module>/ holds a module, its helper modules and its configs;
# specs/<area>/base/ holds the modules they share. SANY and TLC run inside the config's (or
# module's) own folder with -DTLA-Library pointing at that area's base/, so `EXTENDS` and a
# `SPEC:` header resolve from the folder first and from base/ second.
#
# Each config's TLC log is kept at build/tla/<area>/<module>/<cfg>/tlc.log, and each module's
# parse log beside them as <Module>.sany.log (build/ is gitignored). A split TEMPORAL check adds
# tlc.others.log and the two config copies there. TLC's state files are written to <cfg>/states/
# during the run and deleted when it ends.
#
# Environment:
#   JAVA            java binary (default: Homebrew's keg-only openjdk; /usr/bin/java is a stub)
#   TLA_CACHE_DIR   where the pinned tla2tools.jar is cached and the logs are written
#                   (default: build/tla, gitignored)
#   TLC_TIER        default (skip deep configs), deep (run them too) or deep-only
#   TLC_WORKERS     TLC -workers value (default: auto)
#   TLC_HEAP        JVM max heap (default: 4g)
#
# Exit status: 0 all checks passed; 1 a check failed; 2 the checks could not run (no Java, no
# tla2tools.jar, a bad argument or header).
set -euo pipefail

TLA_VERSION="v1.7.4"
TLA_JAR_SHA256="936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"
TLA_JAR_URL="https://github.com/tlaplus/tlaplus/releases/download/${TLA_VERSION}/tla2tools.jar"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPECS_DIR="$ROOT/specs"
CACHE_DIR="${TLA_CACHE_DIR:-$ROOT/build/tla}"
JAR="$CACHE_DIR/tla2tools-${TLA_VERSION}.jar"
WORKERS="${TLC_WORKERS:-auto}"
HEAP="${TLC_HEAP:-4g}"

die() { printf 'check-tla-specs: %s\n' "$*" >&2; exit 2; }

# TLC needs a JDK. A missing one is an error (exit 2), never a skipped check.
NO_JAVA_HELP="TLC needs a JDK and none was found, so no spec was checked. Install Homebrew openjdk (brew install openjdk) or set JAVA=/path/to/bin/java."

find_java() {
  local candidate="" prefix
  if [[ -n "${JAVA:-}" ]]; then
    [[ -x "$JAVA" ]] || die "JAVA=$JAVA is not executable. $NO_JAVA_HELP"
    candidate="$JAVA"
  elif prefix="$(brew --prefix openjdk 2>/dev/null)" && [[ -x "$prefix/bin/java" ]]; then
    candidate="$prefix/bin/java"
  elif [[ "$(uname -s)" != Darwin ]] && command -v java >/dev/null 2>&1; then
    # Off macOS there is no /usr/bin/java stub to avoid, so a java on PATH is a real JDK.
    candidate="$(command -v java)"
  else
    die "$NO_JAVA_HELP"
  fi
  "$candidate" -version >/dev/null 2>&1 \
    || die "$candidate does not run (\`$candidate -version\` failed). $NO_JAVA_HELP"
  printf '%s\n' "$candidate"
}

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

ensure_jar() {
  if [[ -f "$JAR" && "$(sha256_of "$JAR")" == "$TLA_JAR_SHA256" ]]; then
    return
  fi
  mkdir -p "$CACHE_DIR"
  local tmp="$JAR.download.$$"
  printf 'check-tla-specs: downloading tla2tools.jar %s\n' "$TLA_VERSION" >&2
  curl --fail --silent --show-error --location --output "$tmp" "$TLA_JAR_URL" \
    || { rm -f "$tmp"; die "download failed: $TLA_JAR_URL"; }
  local actual
  actual="$(sha256_of "$tmp")"
  if [[ "$actual" != "$TLA_JAR_SHA256" ]]; then
    rm -f "$tmp"
    die "SHA-256 mismatch for tla2tools.jar $TLA_VERSION: expected $TLA_JAR_SHA256, got $actual"
  fi
  mv "$tmp" "$JAR"
}

# Value of a `\* KEY: value` header line in a .cfg file (empty when absent).
cfg_header() {
  sed -n "s/^\\\\\\* *$2: *\\(.*[^ ]\\) *\$/\\1/p" "$1" | head -n 1
}

# Absolute path of an existing file or directory.
absolute() {
  if [[ -d "$1" ]]; then
    (cd "$1" && pwd)
  else
    printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")"
  fi
}

collect() {
  local target
  for target in "$@"; do
    if [[ -d "$target" ]]; then
      find "$target" -type f \( -name '*.tla' -o -name '*.cfg' \) | sort
    else
      printf '%s\n' "$target"
    fi
  done
}

# The shared-module folder for files in directory $1: the `base` folder beside it
# (specs/<area>/base for specs/<area>/<module>). Empty when there is none, or $1 is that folder.
library_dir() {
  local base
  base="$(dirname "$1")/base"
  if [[ -d "$base" && "$base" != "$1" ]]; then printf '%s\n' "$base"; fi
}

# The .tla file a config checks: beside the config, else in the area's base folder.
config_module() {
  local dir spec lib
  dir="$(dirname "$1")"
  spec="$(cfg_header "$1" SPEC)"
  spec="${spec:-$(basename "$1" .cfg)}"
  lib="$(library_dir "$dir")"
  if [[ ! -f "$dir/$spec.tla" && -n "$lib" && -f "$lib/$spec.tla" ]]; then
    printf '%s\n' "$lib/$spec.tla"
  else
    printf '%s\n' "$dir/$spec.tla"
  fi
}

# Where a spec or config's logs go: build/tla/<path under specs/, without the extension>.
# Files outside specs/ use the run's temporary directory.
output_path() {
  local file="${1%.*}"
  case "$file" in
    "$SPECS_DIR"/*) printf '%s\n' "$CACHE_DIR/${file#"$SPECS_DIR"/}" ;;
    *) printf '%s\n' "$WORK/$(printf '%s' "$file" | shasum | cut -c 1-12)-$(basename "$file")" ;;
  esac
}

# The names a config lists under PROPERTY / PROPERTIES, space-separated.
cfg_properties() {
  awk '
    BEGIN {
      split("CONSTANT CONSTANTS INIT NEXT SPECIFICATION INVARIANT INVARIANTS PROPERTY PROPERTIES " \
            "SYMMETRY CONSTRAINT CONSTRAINTS ACTION_CONSTRAINT ACTION_CONSTRAINTS VIEW " \
            "CHECK_DEADLOCK POSTCONDITION ALIAS", words, " ")
      for (w in words) keyword[words[w]] = 1
    }
    {
      sub(/\\\*.*/, "")
      first = 1
      if ($1 in keyword) { inside = ($1 == "PROPERTY" || $1 == "PROPERTIES"); first = 2 }
      if (inside) for (i = first; i <= NF; i++) names = names (names == "" ? "" : " ") $i
    }
    END { print names }
  ' "$1"
}

LIST_ONLY=0
TIER_MODE="${TLC_TIER:-default}"
TARGETS=()
for arg in "$@"; do
  case "$arg" in
    --list) LIST_ONLY=1 ;;
    --deep) TIER_MODE=deep ;;
    --deep-only) TIER_MODE=deep-only ;;
    -h|--help)
      awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
      exit 0 ;;
    -*) die "unknown option: $arg" ;;
    *)
      [[ -e "$arg" ]] || die "no such spec, config or directory: $arg"
      TARGETS+=("$(absolute "$arg")") ;;
  esac
done
case "$TIER_MODE" in
  default|deep|deep-only) ;;
  *) die "unknown tier: $TIER_MODE (use default, deep or deep-only)" ;;
esac
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  [[ -d "$SPECS_DIR" ]] || die "no specs/ directory at $SPECS_DIR"
  TARGETS=("$SPECS_DIR")
fi

# The tier a config declares: default or deep.
cfg_tier() {
  local tier
  tier="$(cfg_header "$1" TIER)"
  case "${tier:-default}" in
    default|deep) printf '%s\n' "${tier:-default}" ;;
    *) die "$1: unrecognized TIER header: $tier (use default or deep)" ;;
  esac
}

MODULES=()
CONFIGS=()
# .cfg files named on the command line run whatever their tier.
NAMED_CONFIGS=""
for target in "${TARGETS[@]}"; do
  if [[ -f "$target" && "$target" == *.cfg ]]; then NAMED_CONFIGS+="$target"$'\n'; fi
done
while IFS= read -r file; do
  case "$file" in
    *.tla)
      MODULES+=("$file")
      # A named module also runs its configs: those that declare it, or share its basename.
      # A shared module's configs can sit in any folder of its area.
      search="$(dirname "$file")"
      if [[ "$(basename "$search")" == base ]]; then search="$(dirname "$search")"; fi
      while IFS= read -r cfg; do
        if [[ "$(config_module "$cfg")" == "$file" ]]; then CONFIGS+=("$cfg"); fi
      done < <(find "$search" -type f -name '*.cfg' | sort)
      ;;
    *.cfg)
      CONFIGS+=("$file")
      MODULES+=("$(config_module "$file")")
      ;;
  esac
done < <(collect "${TARGETS[@]}")

dedupe() { awk 'NF && !seen[$0]++'; }
MODULE_LIST="$(printf '%s\n' "${MODULES[@]:-}" | dedupe)"
ALL_CONFIG_LIST="$(printf '%s\n' "${CONFIGS[@]:-}" | dedupe)"
[[ -n "$MODULE_LIST" ]] || die "no .tla modules found"

CONFIG_LIST=""
SKIPPED_LIST=""
while IFS= read -r cfg; do
  [[ -n "$cfg" ]] || continue
  tier="$(cfg_tier "$cfg")"
  selected=0
  case "$TIER_MODE" in
    default) [[ "$tier" == default ]] && selected=1 ;;
    deep) selected=1 ;;
    deep-only) [[ "$tier" == deep ]] && selected=1 ;;
  esac
  if [[ $selected -eq 0 ]] && grep -Fxq -- "$cfg" <<<"$NAMED_CONFIGS"; then selected=1; fi
  if [[ $selected -eq 1 ]]; then CONFIG_LIST+="$cfg"$'\n'; else SKIPPED_LIST+="$cfg"$'\n'; fi
done <<<"$ALL_CONFIG_LIST"

if [[ "$LIST_ONLY" -eq 1 ]]; then
  printf '%s' "$CONFIG_LIST"
  exit 0
fi

JAVA_BIN="$(find_java)"
ensure_jar

FAILURES=0
FAILED_MODULES=""
SUMMARY=()
WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-tla-specs.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- SANY: every module must parse and pass semantic analysis. ---
while IFS= read -r module; do
  [[ -f "$module" ]] || die "module not found: $module"
  log="$(output_path "$module").sany.log"
  mkdir -p "$(dirname "$log")"
  lib="$(library_dir "$(dirname "$module")")"
  if (cd "$(dirname "$module")" \
        && "$JAVA_BIN" ${lib:+"-DTLA-Library=$lib"} -cp "$JAR" tla2sany.SANY \
            "$(basename "$module")") >"$log" 2>&1 \
      && ! grep -Eq '(\*\*\* Errors|Parsing or semantic analysis failed|Fatal errors|Could not find module)' "$log"; then
    SUMMARY+=("ok    parse  ${module#"$ROOT"/}")
  else
    cat "$log"
    SUMMARY+=("FAIL  parse  ${module#"$ROOT"/}")
    FAILED_MODULES+="$module"$'\n'
    FAILURES=$((FAILURES + 1))
  fi
done <<<"$MODULE_LIST"

# --- TLC: every config must end the way its EXPECT header says. ---

# Run TLC on config $1 (a name in $dir, or an absolute path) with its log at $2.
# Sets TLC_STATUS to the process exit status.
run_tlc() {
  local meta="$out/states"
  mkdir -p "$meta"
  set +e
  # TLC finds $spec.tla in this folder, or through TLA-Library when it is a shared module.
  (cd "$dir" && "$JAVA_BIN" "-Xmx$HEAP" -XX:+UseParallelGC ${lib:+"-DTLA-Library=$lib"} \
      -cp "$JAR" tlc2.TLC -workers "$WORKERS" -metadir "$meta" -config "$1" \
      "$spec.tla") >"$2" 2>&1
  TLC_STATUS=$?
  set -e
  rm -rf "$meta"
}

# What a finished TLC run established, from its exit status ($2) AND its log ($1). Sets RESULT to
#   pass                 exit 0, the "No error has been found" line, no error line
#   <Name>               exactly that invariant or action property violated
#   TEMPORAL | DEADLOCK  a liveness violation, a deadlock
#   BROKEN               anything else: RESULT_WHY says what. Never a pass, never a violation.
# TLC's exit statuses (tlc2.output.EC.ExitStatus): 0 success, 11 deadlock, 12 safety (invariant)
# violation, 13 liveness violation, which TLC 1.7 also uses for an action property; everything
# else (75-77 evaluation failures, 150-153 parse/config errors, 255 an internal error, 137 a
# killed JVM) means TLC did not complete the check. A violation counts only when the status,
# the banner and a clean finish agree: the banner alone can be followed by a crash.
classify_tlc() {
  local log="$1" status="$2" banners count stray
  RESULT=BROKEN
  RESULT_WHY=""
  if grep -Eq 'java\.lang\.[A-Za-z]*(Error|Exception)|Exception in thread|TLC threw an unexpected exception' "$log"; then
    RESULT_WHY="TLC crashed (exit $status): $(grep -Eom1 'java\.lang\.[A-Za-z]*(Error|Exception)|Exception in thread|TLC threw an unexpected exception' "$log")"
    return
  fi
  if ! grep -q '^Finished in ' "$log"; then
    RESULT_WHY="TLC did not finish (exit $status)"
    return
  fi
  banners="$(sed -n \
      -e 's/^Error: Invariant \([A-Za-z0-9_]*\) is violated.*/invariant \1/p' \
      -e 's/^Error: Action property \([A-Za-z0-9_]*\) is violated.*/action \1/p' \
      -e 's/^Error: Temporal properties were violated.*/temporal TEMPORAL/p' \
      -e 's/^Error: Deadlock reached.*/deadlock DEADLOCK/p' "$log")"
  count="$(grep -c . <<<"$banners" || true)"
  # Besides the banner, a counterexample has only these two "Error:" lines.
  stray="$(grep '^Error:' "$log" | grep -Ev \
      '^Error: (Invariant [A-Za-z0-9_]* is violated|Action property [A-Za-z0-9_]* is violated|Temporal properties were violated|Deadlock reached|The behavior up to this point is:|The following behavior constitutes a counter-example:)' \
      | head -n 1 || true)"
  if [[ -n "$stray" ]]; then
    RESULT_WHY="TLC reported an error (exit $status): ${stray#Error: }"
    return
  fi
  if [[ "$status" -eq 0 ]]; then
    if [[ "$count" -eq 0 ]] && grep -q 'Model checking completed. No error has been found.' "$log"; then
      RESULT=pass
    else
      RESULT_WHY="TLC exited 0 without a clean \"No error has been found\""
    fi
    return
  fi
  if [[ "$count" -ne 1 ]]; then
    RESULT_WHY="TLC exit $status with $count violation banners"
    return
  fi
  case "${banners%% *}:$status" in
    invariant:12|action:12|action:13|temporal:13|deadlock:11) RESULT="${banners#* }" ;;
    *) RESULT_WHY="TLC exit $status does not match its banner (${banners#* })" ;;
  esac
}

# Copy config $1 to $2 with its PROPERTY list replaced by the names in $3.
cfg_with_properties() {
  awk -v keep="$3" '
    BEGIN {
      split("CONSTANT CONSTANTS INIT NEXT SPECIFICATION INVARIANT INVARIANTS PROPERTY PROPERTIES " \
            "SYMMETRY CONSTRAINT CONSTRAINTS ACTION_CONSTRAINT ACTION_CONSTRAINTS VIEW " \
            "CHECK_DEADLOCK POSTCONDITION ALIAS", words, " ")
      for (w in words) keyword[words[w]] = 1
    }
    {
      line = $0
      sub(/\\\*.*/, "", line)
      n = split(line, field, " ")
      if (n > 0 && (field[1] in keyword)) inside = (field[1] == "PROPERTY" || field[1] == "PROPERTIES")
      if (inside && n > 0) next
      print
    }
    END { if (keep != "") print "PROPERTY " keep }
  ' "$1" >"$2"
}

print_report() {
  # TLC's report from the first error on (the counterexample trace), or the whole log.
  if grep -q '^Error:' "$1"; then sed -n '/^Error:/,$p' "$1"; else cat "$1"; fi
}

while IFS= read -r cfg; do
  [[ -n "$cfg" ]] || continue
  dir="$(dirname "$cfg")"
  name="$(basename "$cfg" .cfg)"
  spec="$(cfg_header "$cfg" SPEC)"
  spec="${spec:-$name}"
  expect="$(cfg_header "$cfg" EXPECT)"
  expect="${expect:-pass}"
  properties="$(cfg_properties "$cfg")"
  # wanted: what the (first) run must establish. named: the temporal property EXPECT names.
  named=""
  case "$expect" in
    pass) wanted=pass ;;
    "violation TEMPORAL") wanted=TEMPORAL ;;
    "violation TEMPORAL "*)
      wanted=TEMPORAL
      named="${expect#violation TEMPORAL }"
      [[ "$named" =~ ^[A-Za-z0-9_]+$ && " $properties " == *" $named "* ]] \
        || die "$cfg: EXPECT names $named, which is not in the config's PROPERTY list ($properties)"
      ;;
    "violation "*)
      wanted="${expect#violation }"
      [[ "$wanted" =~ ^[A-Za-z0-9_]+$ ]] || die "$cfg: unrecognized EXPECT header: $expect"
      ;;
    *) die "$cfg: unrecognized EXPECT header: $expect" ;;
  esac
  if grep -Fxq -- "$(config_module "$cfg")" <<<"$FAILED_MODULES"; then
    SUMMARY+=("FAIL  tlc    ${cfg#"$ROOT"/}  [expect: $expect; not run: $spec.tla does not parse]")
    FAILURES=$((FAILURES + 1))
    continue
  fi
  if [[ "$wanted" == TEMPORAL && -z "$named" && "$properties" == *" "* ]]; then
    # TLC reports a liveness failure without the property's name, so with several properties
    # an unnamed expectation cannot be checked.
    SUMMARY+=("FAIL  tlc    ${cfg#"$ROOT"/}  [expect: $expect; not run: the config checks several properties (${properties// /, }); name the violated one: EXPECT: violation TEMPORAL <Property>]")
    FAILURES=$((FAILURES + 1))
    continue
  fi
  out="$(output_path "$cfg")"
  log="$out/tlc.log"
  rm -rf "$out"
  mkdir -p "$out"
  lib="$(library_dir "$dir")"
  started=$SECONDS
  others=""
  rest_log=""
  if [[ -n "$named" && "$properties" != "$named" ]]; then
    # Several properties: check the named one alone, then the others without it, so the
    # expected violation is this property's and no other property is violated with it.
    others="$(printf '%s\n' $properties | grep -Fxv -- "$named" | tr '\n' ' ')"
    others="${others% }"
    cfg_with_properties "$cfg" "$out/only-$named.cfg" "$named"
    cfg_with_properties "$cfg" "$out/without-$named.cfg" "$others"
    run_tlc "$out/only-$named.cfg" "$log"
  else
    run_tlc "$name.cfg" "$log"
  fi
  classify_tlc "$log" "$TLC_STATUS"
  states="$(sed -n 's/^\([0-9][0-9]*\) states generated, \([0-9][0-9]*\) distinct states found.*/\2 distinct/p' "$log" | tail -n 1)"
  case "$RESULT" in
    pass) got="no violation" ;;
    BROKEN) got="$RESULT_WHY" ;;
    TEMPORAL)
      # TLC does not say which temporal property failed; the PROPERTY list of the run does.
      if [[ -n "$named" ]]; then got="TEMPORAL ($named)"
      elif [[ -n "$properties" ]]; then got="TEMPORAL ($properties)"
      else got="TEMPORAL"; fi ;;
    *) got="$RESULT" ;;
  esac
  outcome="FAIL"
  if [[ "$RESULT" == "$wanted" ]]; then outcome="ok"; fi
  if [[ "$outcome" == ok && -n "$others" ]]; then
    rest_log="$out/tlc.others.log"
    run_tlc "$out/without-$named.cfg" "$rest_log"
    classify_tlc "$rest_log" "$TLC_STATUS"
    case "$RESULT" in
      pass) got+="; the others hold (${others// /, })" ;;
      BROKEN) outcome="FAIL"; got+="; checking the others (${others// /, }): $RESULT_WHY" ;;
      *) outcome="FAIL"; got+="; also violated among the others (${others// /, }): $RESULT" ;;
    esac
  fi
  elapsed=$((SECONDS - started))
  if [[ "$outcome" == "ok" && "$expect" == "pass" ]]; then
    :
  else
    printf '\n===== %s (%s; expected: %s) =====\n' "${cfg#"$ROOT"/}" "$spec" "$expect"
    print_report "$log"
    if [[ -n "$rest_log" && "$outcome" != ok ]]; then
      printf '\n----- the other properties (%s) -----\n' "$others"
      print_report "$rest_log"
    fi
  fi
  if [[ "$outcome" != "ok" ]]; then FAILURES=$((FAILURES + 1)); fi
  SUMMARY+=("$(printf '%-5s tlc    %s  [expect: %s; got: %s; %s; %ss]' "$outcome" \
      "${cfg#"$ROOT"/}" "$expect" "$got" "${states:-? states}" "$elapsed")")
done <<<"$CONFIG_LIST"

while IFS= read -r cfg; do
  [[ -n "$cfg" ]] || continue
  SUMMARY+=("skip  tlc    ${cfg#"$ROOT"/}  [tier: $(cfg_tier "$cfg"); not in this run]")
done <<<"$SKIPPED_LIST"

printf '\n===== check-tla-specs summary (tla2tools %s; tier: %s) =====\n' "$TLA_VERSION" "$TIER_MODE"
printf '%s\n' "${SUMMARY[@]}"
if [[ $FAILURES -gt 0 ]]; then
  printf '%d check(s) failed\n' "$FAILURES"
  exit 1
fi
printf 'all checks passed\n'
