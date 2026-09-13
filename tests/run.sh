#!/usr/bin/env bash
# run.sh — Run the config's headless test suite.
#
# Runs every tests/*.lua file directly through `nvim --headless`, building fresh
# fixtures (git repo + non-git dir) into a temp dir for each test so no test
# depends on another's mutations. Each test loads the config via normal XDG
# discovery against an isolated temp HOME (the config dir is symlinked into
# $TMPHOME/.config/nvim), so `require()` and rtp work without touching the real
# HOME. Prints a per-test PASS/FAIL line and a summary; exits non-zero if any
# test fails.
#
# Self-sufficient: requires only `nvim` and `timeout` (coreutils) on PATH.
#
# Usage:
#   tests/run.sh                     # all tests
#   tests/run.sh <test-file.lua>     # run just one test file
#   TIMEOUT=60 tests/run.sh          # override per-test timeout (default 30s)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
CONFIG_DIR="$(cd "$HERE/.." && pwd -P)"
TIMEOUT="${TIMEOUT:-30}"

if ! command -v nvim >/dev/null 2>&1; then
  echo "run.sh: nvim not found on PATH" >&2
  exit 3
fi
if ! command -v timeout >/dev/null 2>&1; then
  echo "run.sh: timeout not found on PATH (coreutils)" >&2
  exit 3
fi

# Temp paths to remove. The trap is the backstop if the run is interrupted; the
# loop also cleans up per test once results have been read.
CLEANUP=()
cleanup() {
  if (( ${#CLEANUP[@]} > 0 )); then
    rm -rf "${CLEANUP[@]}" 2>/dev/null || true
    CLEANUP=()
  fi
}
trap cleanup INT TERM EXIT

FILES=()
if [[ $# -gt 0 ]]; then
  FILES+=("$1")
else
  for f in "$HERE"/*.lua; do FILES+=("$f"); done
fi
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "run.sh: no tests found in $HERE" >&2
  exit 2
fi

passed=0
failed=0
failures=()

for testfile in "${FILES[@]}"; do
  name="$(basename "$testfile")"

  # Fresh fixture root per test (per-test isolation; resets any git repo a
  # previous test git-inited inside the non-git dir).
  work="$(mktemp -d)"; CLEANUP+=("$work")
  setup_out="$("$HERE/setup_fixtures.sh" "$work")"
  FIXTURE_REPO="$(printf '%s\n' "$setup_out" | sed -n 's/^FIXTURE_REPO=//p')"
  FIXTURE_NON_GIT="$(printf '%s\n' "$setup_out" | sed -n 's/^FIXTURE_NON_GIT=//p')"

  # Isolated temp HOME; symlink the config so normal XDG discovery loads it.
  TMPHOME="$(mktemp -d)"; CLEANUP+=("$TMPHOME")
  mkdir -p "$TMPHOME/.config"
  ln -s "$CONFIG_DIR" "$TMPHOME/.config/nvim"

  out="$(mktemp)"; err="$(mktemp)"; CLEANUP+=("$out" "$err")

  set +e
  TEST_FIXTURE_DIR="$FIXTURE_REPO" TEST_NON_GIT_DIR="$FIXTURE_NON_GIT" \
    HOME="$TMPHOME" XDG_CONFIG_HOME="$TMPHOME/.config" \
    timeout --signal=KILL "$TIMEOUT" nvim --headless \
      -c "lua dofile([[$(readlink -f "$testfile")]])" +qa! \
      >"$out" 2>"$err"
  rc=$?
  set -e

  # Parse BEFORE any cleanup (order matters).
  if [[ $rc -eq 0 ]] && grep -q '^TEST_RESULT: PASS' "$out"; then
    echo "run.sh: PASS  $name"
    passed=$((passed + 1))
  else
    echo "run.sh: FAIL  $name"
    if [[ $rc -eq 124 || $rc -eq 137 ]]; then
      echo "run.sh:   timed out after ${TIMEOUT}s (rc=$rc)"
    fi
    echo "run.sh:   --- stderr ---"
    cat "$err" || true
    echo "run.sh:   --- stdout ---"
    cat "$out" || true
    failed=$((failed + 1))
    failures+=("$name")
  fi

  rm -rf "${CLEANUP[@]}" 2>/dev/null || true
  CLEANUP=()
done

echo
echo "run.sh: Summary: $passed passed, $failed failed"
if [[ $failed -gt 0 ]]; then
  printf 'run.sh: Failed: %s\n' "${failures[*]}"
  exit 1
fi
exit 0
