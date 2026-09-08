#!/usr/bin/env bash
# The one command that says whether the tree is healthy: both packages' test
# suites with line coverage, and a build of the app scheme for the simulator.
# Exits non-zero on the first failure. Run from anywhere in the repo.
#
#   scripts/check.sh              tests, coverage, and the app build
#   scripts/check.sh --skip-app   tests and coverage only (faster)
#   scripts/check.sh --files      also list per-file coverage

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skip_app=false
show_files=false
for arg in "$@"; do
  case "$arg" in
    --skip-app) skip_app=true ;;
    --files) show_files=true ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# Run one package's tests with coverage and print its summary line and total
# line coverage. The coverage report is scoped to the package's own sources:
# tests, build products, dependencies, and the other package are excluded.
check_package() {
  local name="$1"
  local dir="$root/Packages/$name"
  echo "== $name"
  local log
  log="$(mktemp)"
  if ! (cd "$dir" && swift test --enable-code-coverage >"$log" 2>&1); then
    grep -E "error:|error -|failed" "$log" | sort -u | head -40
    echo "FAIL: $name tests"
    rm -f "$log"
    return 1
  fi
  grep -E "Executed [0-9]+ tests" "$log" | tail -1 | sed 's/^[[:space:]]*//'
  rm -f "$log"

  local binary profile
  # The dSYM bundle holds a same-named copy of the binary; skip it.
  binary="$(find "$dir/.build" -type f -name "${name}PackageTests" -not -path "*.dSYM*" | head -1)"
  profile="$(find "$dir/.build" -name default.profdata | head -1)"
  if [[ -z "$binary" || -z "$profile" ]]; then
    echo "coverage: no profile found"
    return 0
  fi
  # llvm-cov's regex has no lookahead, so the other package is named outright.
  local other
  if [[ "$name" == "ZirbeCore" ]]; then other="ZirbeMail"; else other="ZirbeCore"; fi
  local report
  report="$(cd "$dir" && xcrun llvm-cov report "$binary" -instr-profile "$profile" \
    -ignore-filename-regex="Tests|\.build|checkouts|Packages/$other" 2>/dev/null \
    | grep -E "\.swift|^TOTAL" || true)"
  if $show_files; then
    echo "$report" | awk '$1 != "TOTAL" { sub(".*/", "", $1); printf "  %-32s %s\n", $1, $10 }'
  fi
  echo "$report" | awk '$1 == "TOTAL" { print "coverage: " $10 " of lines" }'
}

check_package ZirbeMail
check_package ZirbeCore

if $skip_app; then
  echo "== app build skipped"
else
  echo "== Zirbe app"
  log="$(mktemp)"
  if (cd "$root/Zirbe" && xcodebuild -scheme Zirbe -destination 'generic/platform=iOS Simulator' build >"$log" 2>&1); then
    echo "build succeeded"
  else
    grep -E "error:" "$log" | sort -u | head -20
    echo "FAIL: app build"
    rm -f "$log"
    exit 1
  fi
  rm -f "$log"
fi

echo "== all checks passed"
