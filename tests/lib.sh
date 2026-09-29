# shellcheck shell=sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 BP3 Global Inc.
#
# lib.sh - helpers for the tests; sourced by run.sh for each test file
#
# A test file defines functions named test_*, and optionally
#   fixture=NAME    serve tests/fixtures/NAME.json from the mock API
#   profiles=NAME   start each test with tests/fixtures/profiles/NAME
#                   copied in as the config directory (default: flat)
#
# In a test:
#   run CMD...              run CMD, stdin from /dev/null, capturing stdout,
#                           stderr and the exit status. There's never a
#                           terminal to confirm with (CAMUNDA_TTY), unless
#   answer TEXT             says what to type when the next command asks
#   run_with INPUT CMD...   the same, with INPUT on stdin
#   c8sh NOUN VERB ARGS...  a command for run: c8sh in the shell under test
#   c8 NAME ARGS...         a command for run: bin/NAME (e.g. an old name)
#   lib FUNCTION ARGS...    a command for run: a lib/camunda.sh function in
#                           the shell under test
#   assert_status N
#   assert_stdout TEXT      exact match (a trailing newline is added; ''
#                           means no output at all)
#   assert_stdout_has TEXT  / assert_stderr_has TEXT   substring
#   assert_stderr_lacks TEXT
#   assert_sent PATTERN [N] the mock received N requests (default: at least
#                           one) whose log line matches the grep PATTERN
#   assert_not_sent PATTERN
#
# The shell under test is $TEST_SHELL, e.g. "bash --posix"; it's left
# unquoted on purpose so that it splits into a command and its options.

TESTS=$ROOT/tests

# --- set-up and tear-down ---------------------------------------------------

setup_file() {
    TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/c8-tests.XXXXXX")
    trap 'teardown_file' EXIT
    trap 'teardown_file; exit 130' INT

    # Nothing from the user's own shell or files may leak in.
    for _var in $(env | sed -n 's/^\(CAMUNDA_[A-Z0-9_]*\)=.*/\1/p'); do
        unset "$_var"
    done
    HOME=$TEST_TMP/home
    CAMUNDA_CONFIG_DIR=$TEST_TMP/config
    XDG_CACHE_HOME=$TEST_TMP/cache
    # No terminal to confirm with, even when run from one: a test must never
    # prompt. Tests that answer use the 'answer' helper.
    CAMUNDA_TTY=$TEST_TMP/no-terminal
    # c8sh runs its commands in the shell under test too.
    C8SH_SHELL=$TEST_SHELL
    export HOME CAMUNDA_CONFIG_DIR XDG_CACHE_HOME CAMUNDA_TTY C8SH_SHELL
    unset C8SH_CUSTOMER C8SH_ENV C8SH_PROG
    unset XDG_CONFIG_HOME
    mkdir -p "$HOME"

    MOCK_URL=http://127.0.0.1:9
    MOCK_LOG=$TEST_TMP/requests.log
    : >"$MOCK_LOG"
    if [ -n "${fixture:-}" ]; then
        start_mock "$TESTS/fixtures/$fixture.json"
    fi
}

teardown_file() {
    if [ -n "${MOCK_PID:-}" ]; then
        kill "$MOCK_PID" 2>/dev/null || :
        wait "$MOCK_PID" 2>/dev/null || :
        MOCK_PID=
    fi
    [ -z "${TEST_TMP:-}" ] || rm -rf "$TEST_TMP"
}

start_mock() {
    python3 "$TESTS/mock_camunda.py" "$1" "$TEST_TMP/port" "$MOCK_LOG" &
    MOCK_PID=$!
    _tries=0
    while [ ! -s "$TEST_TMP/port" ]; do
        _tries=$((_tries + 1))
        [ "$_tries" -lt 100 ] || { echo "mock API didn't start" >&2; exit 1; }
        sleep 0.05 2>/dev/null || sleep 1
    done
    MOCK_URL=http://127.0.0.1:$(cat "$TEST_TMP/port")
}

# A clean slate for each test: fresh profiles, no saved default, no cached
# tokens, an empty request log.
setup_test() {
    rm -rf "$CAMUNDA_CONFIG_DIR" "$XDG_CACHE_HOME"
    mkdir -p "$CAMUNDA_CONFIG_DIR"
    cp -R "$TESTS/fixtures/profiles/${profiles:-flat}/." "$CAMUNDA_CONFIG_DIR/"
    find "$CAMUNDA_CONFIG_DIR" -name '*.env' | while IFS= read -r _f; do
        sed "s|@MOCK@|$MOCK_URL|g" "$_f" >"$_f.new" && mv "$_f.new" "$_f"
        chmod 600 "$_f"
    done
    : >"$MOCK_LOG"
    CAMUNDA_TTY=$TEST_TMP/no-terminal
    rm -f "$TEST_TMP/answer"
    _failed=
}

# answer TEXT : confirm the next change by typing TEXT (in this test only).
answer() {
    printf '%s\n' "$1" >"$TEST_TMP/answer"
    CAMUNDA_TTY=$TEST_TMP/answer
}

# --- running things ------------------------------------------------------

c8sh() {
    $TEST_SHELL "$ROOT/bin/c8sh" "$@"
}

c8() {
    _c8_name=$1
    shift
    $TEST_SHELL "$ROOT/bin/$_c8_name" "$@"
}

lib() {
    $TEST_SHELL -c '. "$0/lib/camunda.sh"; "$@"' "$ROOT" "$@"
}

run() {
    _status=0
    "$@" </dev/null >"$TEST_TMP/stdout" 2>"$TEST_TMP/stderr" || _status=$?
    printf '%s\n' "$_status" >"$TEST_TMP/status"
}

run_with() {
    _input=$1
    shift
    _status=0
    printf '%s' "$_input" | "$@" >"$TEST_TMP/stdout" 2>"$TEST_TMP/stderr" || _status=$?
    printf '%s\n' "$_status" >"$TEST_TMP/status"
}

# --- assertions ------------------------------------------------------------

fail() {
    _failed=1
    printf '    %s\n' "$@"
}

show() {
    printf '    %s:\n' "$1"
    sed 's/^/      | /' "$2"
}

assert_status() {
    _got=$(cat "$TEST_TMP/status")
    if [ "$_got" != "$1" ]; then
        fail "expected exit status $1, got $_got"
        show stderr "$TEST_TMP/stderr"
    fi
}

assert_stdout() {
    if [ -z "$1" ]; then
        : >"$TEST_TMP/expected"
    else
        printf '%s\n' "$1" >"$TEST_TMP/expected"
    fi
    if ! cmp -s "$TEST_TMP/expected" "$TEST_TMP/stdout"; then
        fail "stdout differs (- expected, + got):"
        diff "$TEST_TMP/expected" "$TEST_TMP/stdout" | sed -n 's/^\([<>]\)/\1/p' |
            sed 's/^</      -/; s/^>/      +/'
        show stderr "$TEST_TMP/stderr"
    fi
}

assert_stdout_has() {
    grep -F -- "$1" "$TEST_TMP/stdout" >/dev/null || {
        fail "stdout lacks: $1"
        show stdout "$TEST_TMP/stdout"
    }
}

assert_stderr_has() {
    grep -F -- "$1" "$TEST_TMP/stderr" >/dev/null || {
        fail "stderr lacks: $1"
        show stderr "$TEST_TMP/stderr"
    }
}

assert_stderr_lacks() {
    if grep -F -- "$1" "$TEST_TMP/stderr" >/dev/null; then
        fail "stderr has: $1"
        show stderr "$TEST_TMP/stderr"
    fi
}

assert_sent() {
    _n=$(grep -c -- "$1" "$MOCK_LOG" || :)
    if [ -n "${2:-}" ]; then
        [ "$_n" -eq "$2" ] || { fail "expected $2 request(s) matching $1, got $_n"; show requests "$MOCK_LOG"; }
    else
        [ "$_n" -gt 0 ] || { fail "no request matching $1"; show requests "$MOCK_LOG"; }
    fi
}

assert_not_sent() {
    assert_sent "$1" 0
}
