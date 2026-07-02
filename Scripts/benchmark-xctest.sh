#!/usr/bin/env bash
set -euo pipefail

FILTER="${1:-ParserPerformanceTests}"
LABEL="${2:-$(date -u +%Y%m%dT%H%M%SZ)-$(git rev-parse --short HEAD)}"
BENCH_ROOT="${BENCH_ROOT:-}"
if [[ -z "$BENCH_ROOT" ]]; then
  BENCH_ROOT="/tmp/kaset-perf2-bench"
fi
OUT="$BENCH_ROOT/$LABEL"
mkdir -p "$OUT"

{
  echo "filter=$FILTER"
  echo "label=$LABEL"
  date -u
  git rev-parse HEAD
  sw_vers
  swift --version
  xcodebuild -version 2>/dev/null || true
} | tee "$OUT/env.txt"

run_tests() {
  local mode="$1"
  if [[ "$mode" == "skip-build" ]]; then
    swift test -c release --skip-build --filter "$FILTER" --skip KasetUITests
  else
    swift test -c release --filter "$FILTER" --skip KasetUITests
  fi
}

copy_sparkle_into_xctest_bundle() {
  local products_dir=""
  local show_bin
  show_bin=$(swift build -c release --show-bin-path 2>/dev/null || true)

  for candidate in \
    "$PWD/.build/out/Products/Release" \
    "$PWD/.build/out/arm64-apple-macosx/release" \
    "$PWD/.build/out/x86_64-apple-macosx/release" \
    "$show_bin" \
    "$PWD/.build/release" \
    "$PWD/.build/arm64-apple-macosx/release" \
    "$PWD/.build/x86_64-apple-macosx/release"
  do
    if [[ -n "$candidate" && -d "$candidate/KasetTests.xctest" && -d "$candidate/Sparkle.framework" ]]; then
      products_dir="$candidate"
      break
    fi
  done

  if [[ -z "$products_dir" || ! -d "$products_dir" ]]; then
    echo "Could not locate SwiftPM release XCTest/Sparkle products for Sparkle fallback" >&2
    return 0
  fi

  local xctest_bundle="$products_dir/KasetTests.xctest"
  local sparkle_framework="$products_dir/Sparkle.framework"

  if [[ -d "$xctest_bundle" && -d "$sparkle_framework" ]]; then
    mkdir -p "$xctest_bundle/Contents/Frameworks"
    rm -rf "$xctest_bundle/Contents/Frameworks/Sparkle.framework"
    cp -R "$sparkle_framework" "$xctest_bundle/Contents/Frameworks/"
  fi
}

set +e
run_tests build-and-run 2>&1 | tee "$OUT/test.log"
status=${PIPESTATUS[0]}
set -e

if [[ "$status" -ne 0 ]] && grep -q 'Sparkle.framework' "$OUT/test.log"; then
  copy_sparkle_into_xctest_bundle
  set +e
  run_tests skip-build 2>&1 | tee "$OUT/test-rerun.log"
  status=${PIPESTATUS[0]}
  set -e
  cat "$OUT/test-rerun.log" >> "$OUT/test.log"
fi

perl -ne 'if (/Test Case '\''-\[.* ([^\] ]+)\]'\'' measured \[[^\]]+\] average: ([0-9.]+)/) { print "$1\t$2\n" }' \
  "$OUT/test.log" | tee "$OUT/performance.tsv"

printf 'benchmark_dir=%s\n' "$OUT" | tee "$OUT/location.txt"
exit "$status"
