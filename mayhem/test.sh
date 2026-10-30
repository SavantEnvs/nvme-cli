#!/usr/bin/env bash
#
# mayhem/test.sh — RUN nvme-cli's own meson test suite (unit, mock-device and cli tests, built with
# normal flags by mayhem/build.sh) and report CTRF counts. Never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
: "${SRC:=/mayhem}"
cd "$SRC"
B="$SRC/mayhem/build-tests"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -f "$B/build.ninja" ] || [ ! -x "$B/nvme" ]; then
  echo "test.sh: $B is not built — mayhem/build.sh must run first" >&2
  emit_ctrf meson 0 1
  exit 1
fi

# Known-answer checks on the built binary: the version it reports is the one meson.build declares.
passed=0; failed=0
want=$(sed -n "s/^ *version: *'\([^']*\)'.*/\1/p" meson.build | head -n1)
got=$("$B/nvme" version 2>&1 | sed -n 's/^nvme version \([^ ]*\).*/\1/p' | head -n1)
if [ -n "$want" ] && [ "$got" = "$want" ]; then
  passed=$((passed+1))
else
  echo "test.sh: 'nvme version' printed '$got', meson.build says '$want'" >&2
  failed=$((failed+1))
fi
out=$("$B/nvme" help 2>&1)
if printf '%s\n' "$out" | grep -q 'list-subsys' && printf '%s\n' "$out" | grep -q 'get-log'; then
  passed=$((passed+1))
else
  echo "test.sh: 'nvme help' lacks the list-subsys / get-log commands" >&2
  failed=$((failed+1))
fi

log=$(mktemp)
meson test -C "$B" --no-rebuild --num-processes "$MAYHEM_JOBS" --print-errorlogs >"$log" 2>&1
tail -n 30 "$log"
num() { sed -n "s/^$1: *\([0-9][0-9]*\).*/\1/p" "$log" | tail -n1; }
ok=$(num 'Ok'); xfail=$(num 'Expected Fail'); fail=$(num 'Fail'); upass=$(num 'Unexpected Pass')
skip=$(num 'Skipped'); tmo=$(num 'Timeout')
rm -f "$log"
if [ -z "$ok" ]; then
  echo "test.sh: no meson test summary — the suite did not run" >&2
  failed=$((failed+1))
fi
passed=$(( passed + ${ok:-0} + ${xfail:-0} ))
failed=$(( failed + ${fail:-0} + ${upass:-0} + ${tmo:-0} ))
emit_ctrf meson "$passed" "$failed" "${skip:-0}"
