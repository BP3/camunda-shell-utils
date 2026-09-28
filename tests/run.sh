#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 BP3 Global Inc.
#
# run.sh - run the tests, in every POSIX shell available
#
#   tests/run.sh                    every test file, every shell
#   tests/run.sh tests/test_x.sh    just these files
#   TEST_SHELLS='dash' tests/run.sh just these shells (separate with ';')
#   TEST_JOBS=2 tests/run.sh        how many test files run at once (default 4)
#
# Needs python3 for the mock API. Never touches a real cluster: every test
# runs with its own config, cache and HOME, pointed at the mock.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
export ROOT

# The shells to test in; say which are missing, so the list never looks
# like more coverage than a run gives.
if [ -z "${TEST_SHELLS:-}" ]; then
    TEST_SHELLS=
    for candidate in 'dash' 'bash --posix' 'zsh --emulate sh' 'busybox sh'; do
        if ! command -v "${candidate%% *}" >/dev/null 2>&1; then
            echo "skipping $candidate: ${candidate%% *} is not installed"
            continue
        fi
        if [ "$candidate" = 'busybox sh' ] && ! busybox sh -c : 2>/dev/null; then
            echo "skipping $candidate: this busybox has no sh"
            continue
        fi
        TEST_SHELLS="$TEST_SHELLS${TEST_SHELLS:+;}$candidate"
    done
fi
[ -n "$TEST_SHELLS" ] || { echo "run.sh: no shells to test in" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "run.sh: python3 is needed for the mock API" >&2; exit 2; }

if [ $# -eq 0 ]; then
    set -- "$ROOT"/tests/test_*.sh
fi

# Each (shell, file) pair is a job, in its own process so its settings stay
# its own; TEST_JOBS of them run at once. Results are shown in order after.
RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/c8-run.XXXXXX")
trap 'rm -rf "$RUN_TMP"' EXIT
# Default 4: each job starts hundreds of short processes (sh, curl, jq), so
# more jobs than that mostly compete for the CPU (measured on an 8-core Mac).
jobs=${TEST_JOBS:-4}
case $jobs in '' | *[!0-9]* | 0) echo "run.sh: TEST_JOBS must be a positive number" >&2; exit 2 ;; esac

n=0
running=0
IFS_SAVED=$IFS
IFS=';'
for shell in $TEST_SHELLS; do
    IFS=$IFS_SAVED
    for file in "$@"; do
        n=$((n + 1))
        id=$(printf '%04d' "$n")
        printf '%s\n' "$shell" >"$RUN_TMP/$id.shell"
        printf '%s\n' "${file##*/}" >"$RUN_TMP/$id.name"
        TEST_SHELL=$shell sh -c '
            . "$ROOT/tests/lib.sh"
            . "$1"
            setup_file
            for t in $(sed -n "s/^\(test_[A-Za-z0-9_]*\)() *{.*/\1/p" "$1"); do
                setup_test
                "$t"
                if [ -n "$_failed" ]; then echo "FAIL $t"; else echo "PASS $t"; fi
            done' sh "$file" >"$RUN_TMP/$id.out" 2>&1 &
        running=$((running + 1))
        if [ "$running" -ge "$jobs" ]; then
            wait
            running=0
        fi
    done
    IFS=';'
done
IFS=$IFS_SAVED
wait

passed=0
failed=0
current=
for out in "$RUN_TMP"/*.out; do
    id=${out%.out}
    shell=$(cat "$id.shell")
    name=$(cat "$id.name")
    if [ "$shell" != "$current" ]; then
        printf '== %s\n' "$shell"
        current=$shell
    fi
    while IFS= read -r line; do
        case $line in
            'PASS '*) ;;
            'FAIL '*) printf '  FAIL %s: %s\n' "$name" "${line#FAIL }" ;;
            *) printf '%s\n' "$line" ;;
        esac
    done <"$out"
    p=$(grep -c '^PASS ' "$out" || :)
    f=$(grep -c '^FAIL ' "$out" || :)
    printf '  %-36s %3d passed %3d failed\n' "$name" "$p" "$f"
    passed=$((passed + p))
    failed=$((failed + f))
done

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
