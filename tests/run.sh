#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 BP3 Global Inc.
#
# run.sh - run the tests, in every POSIX shell available
#
#   tests/run.sh                    every test file, every shell
#   tests/run.sh tests/test_x.sh    just these files
#   TEST_SHELLS='dash' tests/run.sh just these shells (separate with ';')
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

passed=0
failed=0
failures=
IFS_SAVED=$IFS
IFS=';'
for shell in $TEST_SHELLS; do
    IFS=$IFS_SAVED
    printf '== %s\n' "$shell"
    for file in "$@"; do
        # Each file runs in its own process, so its settings stay its own.
        results=$(TEST_SHELL=$shell sh -c '
            . "$ROOT/tests/lib.sh"
            . "$1"
            setup_file
            for t in $(sed -n "s/^\(test_[A-Za-z0-9_]*\)() *{.*/\1/p" "$1"); do
                setup_test
                "$t"
                if [ -n "$_failed" ]; then echo "FAIL $t"; else echo "PASS $t"; fi
            done' sh "$file" 2>&1)
        name=${file##*/}
        printf '%s\n' "$results" | while IFS= read -r line; do
            case $line in
                'PASS '*) ;;
                'FAIL '*) printf '  FAIL %s: %s\n' "$name" "${line#FAIL }" ;;
                *) printf '%s\n' "$line" ;;
            esac
        done
        p=$(printf '%s\n' "$results" | grep -c '^PASS ' || :)
        f=$(printf '%s\n' "$results" | grep -c '^FAIL ' || :)
        printf '  %-36s %3d passed %3d failed\n' "$name" "$p" "$f"
        passed=$((passed + p))
        failed=$((failed + f))
        [ "$f" -eq 0 ] || failures="$failures $shell:$name"
    done
    IFS=';'
done
IFS=$IFS_SAVED

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
