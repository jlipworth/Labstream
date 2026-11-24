#!/usr/bin/env bash
# Parse (SANY) and model-check (TLC) every TLA+ spec/config pair under specs/.
#
# Usage:
#   scripts/check-tla-specs.sh                 # every module and every .cfg under specs/
#   scripts/check-tla-specs.sh PATH...         # only these .cfg/.tla files or directories
#   scripts/check-tla-specs.sh --list          # print the configs that would run
#
# Each TLC run is a `<Name>.cfg` file. Its first lines declare the run:
#   \* SPEC: DownloadsSessionCore            (module to check; default: the .cfg basename)
#   \* EXPECT: pass                          (default)
#   \* EXPECT: violation FinishedBodyNotLost (TLC must report exactly this property violated)
# An "EXPECT: violation" config is a faithfulness or known-finding check: the run fails when TLC
# passes, or when it reports a different property. Counterexamples are always printed.
#
# Environment:
#   JAVA            java binary (default: Homebrew's keg-only openjdk; /usr/bin/java is a stub)
#   TLA_CACHE_DIR   where the pinned tla2tools.jar is cached (default: build/tla, gitignored)
#   TLC_WORKERS     TLC -workers value (default: auto)
#   TLC_HEAP        JVM max heap (default: 4g)
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

find_java() {
  if [[ -n "${JAVA:-}" ]]; then
    [[ -x "$JAVA" ]] || die "JAVA=$JAVA is not executable"
    printf '%s\n' "$JAVA"
    return
  fi
  local prefix
  prefix="$(brew --prefix openjdk 2>/dev/null)" \
    || die "no JAVA override and Homebrew openjdk not found (brew install openjdk)"
  [[ -x "$prefix/bin/java" ]] || die "$prefix/bin/java is missing (brew install openjdk)"
  printf '%s\n' "$prefix/bin/java"
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

collect() {
  local target
  for target in "$@"; do
    if [[ -d "$target" ]]; then
      find "$target" -type f \( -name '*.tla' -o -name '*.cfg' \) | sort
    elif [[ -f "$target" ]]; then
      printf '%s\n' "$target"
    else
      die "no such spec, config or directory: $target"
    fi
  done
}

LIST_ONLY=0
TARGETS=()
for arg in "$@"; do
  case "$arg" in
    --list) LIST_ONLY=1 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $arg" ;;
    *) TARGETS+=("$arg") ;;
  esac
done
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  [[ -d "$SPECS_DIR" ]] || die "no specs/ directory at $SPECS_DIR"
  TARGETS=("$SPECS_DIR")
fi

MODULES=()
CONFIGS=()
while IFS= read -r file; do
  case "$file" in
    *.tla)
      MODULES+=("$file")
      # A named module also runs its configs: those that declare it, or share its basename.
      module="$(basename "$file" .tla)"
      for cfg in "$(dirname "$file")"/*.cfg; do
        [[ -f "$cfg" ]] || continue
        declared="$(cfg_header "$cfg" SPEC)"
        if [[ "${declared:-$(basename "$cfg" .cfg)}" == "$module" ]]; then CONFIGS+=("$cfg"); fi
      done
      ;;
    *.cfg)
      CONFIGS+=("$file")
      declared="$(cfg_header "$file" SPEC)"
      MODULES+=("$(dirname "$file")/${declared:-$(basename "$file" .cfg)}.tla")
      ;;
  esac
done < <(collect "${TARGETS[@]}")

dedupe() { awk 'NF && !seen[$0]++'; }
MODULE_LIST="$(printf '%s\n' "${MODULES[@]:-}" | dedupe)"
CONFIG_LIST="$(printf '%s\n' "${CONFIGS[@]:-}" | dedupe)"
[[ -n "$MODULE_LIST" ]] || die "no .tla modules found"

if [[ "$LIST_ONLY" -eq 1 ]]; then
  printf '%s\n' "$CONFIG_LIST"
  exit 0
fi

JAVA_BIN="$(find_java)"
ensure_jar

FAILURES=0
SUMMARY=()
WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-tla-specs.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- SANY: every module must parse and pass semantic analysis. ---
while IFS= read -r module; do
  [[ -f "$module" ]] || die "module not found: $module"
  log="$WORK/sany-$(basename "$module").log"
  if (cd "$(dirname "$module")" \
        && "$JAVA_BIN" -cp "$JAR" tla2sany.SANY "$(basename "$module")") >"$log" 2>&1 \
      && ! grep -Eq '(\*\*\* Errors|Parsing or semantic analysis failed|Fatal errors|Could not find module)' "$log"; then
    SUMMARY+=("ok    parse  ${module#"$ROOT"/}")
  else
    cat "$log"
    SUMMARY+=("FAIL  parse  ${module#"$ROOT"/}")
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
  log="$WORK/tlc-$name.log"
  meta="$WORK/meta-$name"
  mkdir -p "$meta"
  started=$SECONDS
  set +e
  (cd "$dir" && "$JAVA_BIN" "-Xmx$HEAP" -XX:+UseParallelGC -cp "$JAR" tlc2.TLC \
      -workers "$WORKERS" -metadir "$meta" -config "$name.cfg" "$spec.tla") >"$log" 2>&1
  status=$?
  set -e
  elapsed=$((SECONDS - started))
  states="$(sed -n 's/^\([0-9][0-9]*\) states generated, \([0-9][0-9]*\) distinct states found.*/\2 distinct/p' "$log" | tail -n 1)"
  violated="$(sed -n \
      -e 's/^Error: Invariant \([A-Za-z0-9_]*\) is violated.*/\1/p' \
      -e 's/^Error: Action property \([A-Za-z0-9_]*\) is violated.*/\1/p' \
      -e 's/^Error: Temporal properties were violated.*/TEMPORAL/p' \
      -e 's/^Error: Deadlock reached.*/DEADLOCK/p' "$log" | head -n 1)"
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
      "${cfg#"$ROOT"/}" "$expect" "${violated:-no violation}" "${states:-? states}" "$elapsed")")
done <<<"$CONFIG_LIST"

printf '\n===== check-tla-specs summary (tla2tools %s) =====\n' "$TLA_VERSION"
printf '%s\n' "${SUMMARY[@]}"
if [[ $FAILURES -gt 0 ]]; then
  printf '%d check(s) failed\n' "$FAILURES"
  exit 1
fi
printf 'all checks passed\n'
