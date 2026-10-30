#!/usr/bin/env bash
#
# mayhem/build.sh — build nvme-cli's libFuzzer targets (upstream's tests/fuzz, built by its own
# -Dfuzzing=true meson mode) with ASan+UBSan, plus a clean, normal-flags build for mayhem/test.sh.
#
# Runs in the commit image as `mayhem` in /mayhem; re-runnable and offline (meson wrap_mode is
# nofallback, every dependency is an apt -dev package baked into the image).
#
#   mayhem/build-fuzz/tests/fuzz/fuzz-<t>              libFuzzer binary (the Mayhem target)
#   mayhem/build-fuzz/tests/fuzz/fuzz-<t>-standalone   run-once reproducer (one input file, no libFuzzer)
#   mayhem/build-tests/                                normal-flags build whose `meson test` is test.sh
#
# The fuzz binaries stay in the build tree: they link libnvme.so through a build-tree RUNPATH.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export CC CXX

SRC="${SRC:-/mayhem}"
cd "$SRC"
M="$SRC/mayhem"
TARGETS=(argconfig ini global-config fabrics-conf device iostat nbft)

rm -rf "$M/build-fuzz" "$M/build-tests" "$M/build-obj"
mkdir -p "$M/build-obj"

# Upstream's -Dfuzzing=true needs a meson sanitizer (it errors without one). Take the set from
# SANITIZER_FLAGS; with the empty off-switch, keep meson satisfied with `undefined` and switch every
# check off again with -fno-sanitize=all (later on the command line, so it wins).
san=$(printf '%s\n' "$SANITIZER_FLAGS" | grep -o -- '-fsanitize=[^ ]*' | head -n1 | cut -d= -f2 || true)
nosan=""
if [ -z "$san" ]; then san=undefined; nosan="-fno-sanitize=all"; fi

# Leak detection off at build time (ASan/UBSan stay on): the hook is linked into every fuzz binary.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$M/lsan_off.c" -o "$M/build-obj/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$M/build-obj/standalone_main.o"

# 1) sanitized fuzz build: the project itself carries $SANITIZER_FLAGS and DWARF 3
meson setup "$M/build-fuzz" \
    --buildtype=debugoptimized \
    -Dfuzzing=true \
    -Db_sanitize="$san" \
    -Db_lundef=false \
    -Dc_args="$SANITIZER_FLAGS $DEBUG_FLAGS $nosan" \
    -Dc_link_args="$M/build-obj/lsan_off.o $nosan"
meson compile -C "$M/build-fuzz" -j "$MAYHEM_JOBS" $(printf 'tests/fuzz/fuzz-%s ' "${TARGETS[@]}")

# A harness with a copy at mayhem/fuzz-<t>/fuzz-<t>.c replaces upstream's tests/fuzz/fuzz-<t>.c: recompile
# that one object with meson's own compile line (source swapped) and relink with meson's link line.
for t in "${TARGETS[@]}"; do
    src="$M/fuzz-$t/fuzz-$t.c"
    [ -f "$src" ] || continue
    bin="tests/fuzz/fuzz-$t"
    cmds=$(ninja -C "$M/build-fuzz" -t commands "$bin")
    old="-c ../../tests/fuzz/fuzz-$t.c"
    cc=$(printf '%s\n' "$cmds" | grep -F -- " $old" | head -n1)
    [ -n "$cc" ] || { echo "no compile line for tests/fuzz/fuzz-$t.c" >&2; exit 1; }
    (cd "$M/build-fuzz" && bash -c "${cc//"$old"/-c $src}" && bash -c "$(printf '%s\n' "$cmds" | tail -n1)")
    [ -x "$M/build-fuzz/$bin" ] || { echo "missing fuzz target $bin" >&2; exit 1; }
done

# 2) standalone reproducers: replay each libFuzzer link line with the run-once driver in place of
#    the fuzzer runtime
for t in "${TARGETS[@]}"; do
    bin="tests/fuzz/fuzz-$t"
    [ -x "$M/build-fuzz/$bin" ] || { echo "missing fuzz target $bin" >&2; exit 1; }
    link=$(ninja -C "$M/build-fuzz" -t commands "$bin" | tail -n1)
    link=${link// $LIB_FUZZING_ENGINE / $M/build-obj/standalone_main.o }
    link=${link// -o $bin / -o $bin-standalone }
    (cd "$M/build-fuzz" && bash -c "$link")
    [ -x "$M/build-fuzz/$bin-standalone" ] || { echo "missing standalone $bin" >&2; exit 1; }
done

# 3) the project's own suite with its NORMAL flags (no sanitizers, no -gdwarf-3), for mayhem/test.sh
meson setup "$M/build-tests" \
    --buildtype=debugoptimized \
    -Dc_args="$COVERAGE_FLAGS" \
    -Dc_link_args="$COVERAGE_FLAGS"
meson compile -C "$M/build-tests" -j "$MAYHEM_JOBS"
