# Contributing

Thanks for helping. This guide covers how the commands are put together and
how to add one. The rules the code relies on, shell pitfalls we've hit, and
Camunda API behaviour that isn't obvious are in [`CLAUDE.md`](CLAUDE.md):
read that too. It's written for Claude Code, but it's the project's rule book.

## Setting up

You need a POSIX shell, `curl`, `jq`, and Python 3 (for the tests' mock
API). On Windows, clone inside WSL, not under `/mnt/c`.

```sh
git clone git@github.com:BP3/camunda-shell-utils.git
cd camunda-shell-utils
tests/run.sh
```

To try commands against a real cluster, set up a profile as in the README,
and use `--dry-run` for anything that changes things.

Optional: install `dash` (and `busybox`) so the tests run in them too, and
`shellcheck`.

## How a command is put together

Every command in `bin/` follows the same shape. [`bin/c8-topology`](bin/c8-topology)
is the smallest:

1. **Header**: shebang, license lines, and a comment saying what it does.
2. **Find the library**: the `self=$0` loop follows symlinks so the command
   works when linked from `~/bin`, then sources `lib/camunda.sh`.
3. **`usage`**: the `--help` text. It says what the command prints.
4. **Options**: a `while`/`case` loop. The command's own options come first;
   `camunda_common_option` handles `-c`, `-e` and `-h` and rejects the rest.
5. **Operands**: checked before anything talks to the API.
6. **`camunda_load_profile`**: works out the customer and environment, reads
   the profiles, and sets up auth. Nothing is sent yet.
7. **The work**: API calls through the library, data to stdout, messages to
   stderr.

## The library by task

Each function is documented where it's defined in [`lib/camunda.sh`](lib/camunda.sh).

| To... | Use |
|---|---|
| report an error, a warning, a usage mistake | `camunda_die`, `camunda_warn`, `camunda_usage_error` (exits 2) |
| handle `-c`/`-e`/`-h` | `camunda_common_option "$@"`, then `shift "$_camunda_shift"` |
| load the profile | `camunda_load_profile` (sets `CAMUNDA_LABEL`, `CAMUNDA_TMPDIR`, ...) |
| call the API | `camunda_api METHOD PATH [CURL-ARGS...]`, e.g. `camunda_api GET /topology` |
| run a search to the end, all pages | `camunda_search PATH QUERY`: one JSON item per line |
| need a tool | `camunda_require_command jq` |
| take process versions as operands or stdin | `camunda_check_version_args "$@"` (before loading), then `camunda_resolve_versions "$@"` → `$CAMUNDA_TARGETS` (`id version key` lines) |
| pick versions with selectors yourself | `camunda_select_versions SELECTOR...`, `camunda_format_ranges` |
| find the targets' instances | `camunda_find_instances FILTER OUTFILE` |
| count or list them per version | `camunda_count_instances FILE`, `camunda_list_instances FILE` |
| follow call trees | `camunda_find_descendants KEYS FILTER OUTFILE`, `camunda_plan_trees ROOTS CALLED` |
| change things | `camunda_check_keys FILE`, `camunda_confirm "what"`, `camunda_run_batches PATH FILTER` |

Temporary files go in `$CAMUNDA_TMPDIR`, which is private and removed when
the command exits.

## Adding a command: a worked example

Say we want `c8-count-active-instances`: for chosen versions, print
`processDefinitionId version count`. It takes versions the same ways as the
cancel and delete commands, so the library does nearly everything:

```sh
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 BP3 Global Inc.
#
# c8-count-active-instances - count the active instances of process versions
#
#   c8-count-active-instances Process_X newest 5
#   c8-list-process-versions Process_X | c8-count-active-instances

set -eu

# Find lib/ next to bin/, following symlinks (e.g. from ~/bin).
self=$0
while [ -L "$self" ]; do
    link=$(readlink "$self")
    case $link in
        /*) self=$link ;;
        *) self=$(dirname "$self")/$link ;;
    esac
done
. "$(cd "$(dirname "$self")/.." && pwd)/lib/camunda.sh"

usage() {
    cat <<USAGE
Usage: ${0##*/} [OPTION]... [PROCESS_ID VERSIONS...]

Count the active instances of each process version:

  processDefinitionId version count

Versions are chosen as for c8-cancel-process-instances (see its --help), or
piped in as "processDefinitionId version" lines.

Options:
  -c, --customer NAME         customer profile to use
  -e, --environment-name ENV  environment to use
  -h, --help                  show this help and exit
USAGE
}

while [ $# -gt 0 ]; do
    case $1 in
        --) shift; break ;;
        -?*) camunda_common_option "$@"; shift "$_camunda_shift" ;;
        *) break ;;
    esac
done

camunda_check_version_args "$@"     # usage mistakes, before anything else
camunda_load_profile                # customer, environment, settings
status=0
camunda_resolve_versions "$@" || status=$?     # -> $CAMUNDA_TARGETS
[ -s "$CAMUNDA_TARGETS" ] || exit "$status"

camunda_find_instances '{"state": "ACTIVE"}' "$CAMUNDA_TMPDIR/active"
camunda_count_instances "$CAMUNDA_TMPDIR/active" | awk '{ print $1, $2, $4 }'
exit "$status"
```

Things to notice:

- **`camunda_check_version_args` comes before `camunda_load_profile`**, so
  a typo such as `oldest ten` is reported before anything else happens.
- **`camunda_resolve_versions` returns 1** when some versions weren't
  deployed. Keep going with the rest, and exit with that status at the end.
- **Output is data only**, one line per version, so it can be piped on. The
  library's messages (`selected ...`, `not considered ...`) go to stderr.
- **It only reads.** A command that changes things also needs `--dry-run`,
  `-y`, `camunda_check_keys` and `camunda_confirm`, in that order before the
  first request: see `bin/c8-cancel-process-instances`.

Then:

1. Make it executable: `chmod +x bin/c8-count-active-instances`.
2. Add it to the command table in the README.
3. Write its tests.

## Writing tests

Tests live in `tests/test_*.sh`. Each is a set of `test_*` functions that
run a command against the mock API and check what it printed, what it exited
with, and what it sent. This is the example command's test file:

```sh
# shellcheck shell=sh
# c8-count-active-instances. In the fixture, P_A v2 has two active
# instances (1, a root, and 92, called by P_B's root); P_A v1 has none.

fixture=basic

test_counts_per_version() {
    run c8 c8-count-active-instances -e mock P_A all
    assert_status 0
    assert_stdout 'P_A 1 0
P_A 2 2'
    assert_stderr_has 'not considered: 3 (deleted)'
}

test_versions_from_a_pipe() {
    run_with 'P_B 1
P_A 2
' c8 c8-count-active-instances -e mock
    assert_stdout 'P_B 1 1
P_A 2 2'
}

test_only_searches() {
    run c8 c8-count-active-instances -e mock P_A 2
    assert_sent '/search'
    assert_not_sent 'cancellation'
    assert_not_sent 'deletion'
}
```

- **`fixture=basic`** serves [`tests/fixtures/basic.json`](tests/fixtures/basic.json).
  Its comments say what each process and instance is for; reuse them where
  you can, and add data (with a comment) where you can't.
- **`run`** runs a command; **`run_with INPUT`** pipes INPUT into it;
  **`c8 NAME`** is `bin/NAME` in the shell under test.
- **Profiles:** `-e mock` needs no confirmation and `-e prod` does. Set
  `profiles=customers` for the per-customer layout (acme dev/prod, globex dev).
- **Confirmation:** there's never a terminal. `answer 'prod'` types the next
  answer; without it, a command that asks is refused.
- **`assert_sent PATTERN [N]`** greps the mock's request log, one JSON line
  per request, e.g. `assert_sent '/v2/resources/101/deletion' 1`.
- All helpers are listed at the top of [`tests/lib.sh`](tests/lib.sh).

**Make sure a new test can fail.** Break it on purpose (change an expected
line) and check it fails before trusting it. Tests here have passed for the
wrong reason: a confirmation test that used a version with active instances
never reached the prompt, and a version selector after a process id
swallowed the operands meant for something else.

Run just your file while working, then everything:

```sh
TEST_SHELLS=dash tests/run.sh tests/test_count_active_instances.sh
tests/run.sh
```

## Before opening a pull request

- [ ] Branched from an up-to-date `main`
- [ ] `tests/run.sh` passes in every shell it finds
- [ ] New behaviour has tests, and a fix has the test that would have caught it
- [ ] `--help`, the comment at the top of the script, and the README agree
      with what it does
- [ ] New files have the license header
- [ ] Nothing real in the diff: no client ids, secrets, cluster ids or
      customer names (use the fixtures' `mock`, `acme`, `P_A` style)
- [ ] Anything that changes a cluster was only ever run with `--dry-run`
      against real environments
