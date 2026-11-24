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
#   \* EXPECT: violation FinishedBodyNotLost (TLC must report exactly this property violated)
#   \* TIER: deep                            (default: default)
# An "EXPECT: violation" config is a faithfulness or known-finding check: the run fails when TLC
# passes, or when it reports a different property. Counterexamples are always printed.
# TLC reports a failed liveness property only as "Temporal properties were violated", so those
# configs say `EXPECT: violation TEMPORAL`. The summary adds the name from the config's PROPERTY
# list: the property itself when the config checks one, the candidates when it checks several.
# A deep config is skipped unless --deep, --deep-only or TLC_TIER asks for it, or the .cfg file
# itself is named on the command line. Every module is parsed whatever the tier.
#
# Layout: specs/<area>/<module>/ holds a module, its helper modules and its configs;
# specs/<area>/base/ holds the modules they share. SANY and TLC run inside the config's (or
# module's) own folder with -DTLA-Library pointing at that area's base/, so `EXTENDS` and a
# `SPEC:` header resolve from the folder first and from base/ second.
#
# Each config's TLC log is kept at build/tla/<area>/<module>/<cfg>/tlc.log, and each module's
# parse log beside them as <Module>.sany.log (build/ is gitignored). TLC's state files are written
# to <cfg>/states/ during the run and deleted when it ends.
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
while IFS= read -r cfg; do
  [[ -n "$cfg" ]] || continue
  dir="$(dirname "$cfg")"
  name="$(basename "$cfg" .cfg)"
  spec="$(cfg_header "$cfg" SPEC)"
  spec="${spec:-$name}"
  expect="$(cfg_header "$cfg" EXPECT)"
  expect="${expect:-pass}"
  if grep -Fxq -- "$(config_module "$cfg")" <<<"$FAILED_MODULES"; then
    SUMMARY+=("FAIL  tlc    ${cfg#"$ROOT"/}  [expect: $expect; not run: $spec.tla does not parse]")
    FAILURES=$((FAILURES + 1))
    continue
  fi
  out="$(output_path "$cfg")"
  log="$out/tlc.log"
  meta="$out/states"
  rm -rf "$out"
  mkdir -p "$meta"
  lib="$(library_dir "$dir")"
  started=$SECONDS
  set +e
  # TLC finds $spec.tla in this folder, or through TLA-Library when it is a shared module.
  (cd "$dir" && "$JAVA_BIN" "-Xmx$HEAP" -XX:+UseParallelGC ${lib:+"-DTLA-Library=$lib"} \
      -cp "$JAR" tlc2.TLC -workers "$WORKERS" -metadir "$meta" -config "$name.cfg" \
      "$spec.tla") >"$log" 2>&1
  status=$?
  set -e
  rm -rf "$meta"
  elapsed=$((SECONDS - started))
  states="$(sed -n 's/^\([0-9][0-9]*\) states generated, \([0-9][0-9]*\) distinct states found.*/\2 distinct/p' "$log" | tail -n 1)"
  violated="$(sed -n \
      -e 's/^Error: Invariant \([A-Za-z0-9_]*\) is violated.*/\1/p' \
      -e 's/^Error: Action property \([A-Za-z0-9_]*\) is violated.*/\1/p' \
      -e 's/^Error: Temporal properties were violated.*/TEMPORAL/p' \
      -e 's/^Error: Deadlock reached.*/DEADLOCK/p' "$log" | head -n 1)"
  got="${violated:-no violation}"
  if [[ "$violated" == TEMPORAL ]]; then
    # TLC does not say which temporal property failed. The config's PROPERTY list does when it
    # holds one name; with several, any of them may be the one.
    properties="$(cfg_properties "$cfg")"
    case "$properties" in
      "") ;;
      *" "*) got="TEMPORAL (one of: ${properties// /, })" ;;
      *) got="TEMPORAL ($properties)" ;;
    esac
  fi
  outcome="FAIL"
  case "$expect" in
    pass)
      if [[ $status -eq 0 && -z "$violated" ]] \
          && grep -q 'Model checking completed. No error has been found.' "$log"; then
        outcome="ok"
      fi
      ;;
    "violation "*)
      wanted="${expect#violation }"
      if [[ -n "$violated" && "$violated" == "$wanted" ]]; then outcome="ok"; fi
      ;;
    *) die "$cfg: unrecognized EXPECT header: $expect" ;;
  esac
  if [[ "$outcome" == "ok" && "$expect" == "pass" ]]; then
    :
  else
    printf '\n===== %s (%s; expected: %s) =====\n' "${cfg#"$ROOT"/}" "$spec" "$expect"
    # Print TLC's report from the first error on: the counterexample trace.
    if grep -q '^Error:' "$log"; then
      sed -n '/^Error:/,$p' "$log"
    else
      cat "$log"
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
