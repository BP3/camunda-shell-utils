# CLAUDE.md

Shell tools (`c8-*`) for the Camunda 8 Orchestration API (REST `/v2`), in
plain POSIX `sh` with `curl` and `jq`. They target Camunda SaaS and
self-managed clusters, several customers each with several environments,
and they run on macOS, Linux and Windows (WSL). See the README for what each
command does.

## Layout

- `bin/c8sh`: the one command. It dispatches `c8sh NOUN VERB` to
  `libexec/c8sh/NOUN-VERB` (or `libexec/c8sh/NOUN`, for a noun that handles
  its own verbs, like `profile`), and builds `c8sh --help` from each file's
  header line
- `libexec/c8sh/*`: one file per command; `cluster-topology` is the minimal
  template
- `bin/c8-*`: the old command names, kept for now as wrappers that point to
  `c8sh`; they'll be removed
- `lib/camunda.sh`: everything shared: profiles, auth, API calls, paging,
  version selectors, call trees, batches, confirmation. Each function is
  documented where it's defined
- `tests/`: `run.sh` (runner), `lib.sh` (helpers), `mock_camunda.py` (mock
  API), `fixtures/` (data and profiles), `test_*.sh`
- `profiles/*.example`: templates for `~/.config/camunda/`
- `CONTRIBUTING.md`: how a command is put together, the library by task, and
  a worked example of adding a command and its tests

## Working here

- **Branch from an up-to-date `main`** (`git fetch && git switch main &&
  git pull --ff-only` first) and change things through pull requests; never
  commit to `main`.
- **Run `tests/run.sh` before every PR**; it must pass in every shell it
  finds. GitHub Actions runs it again on Ubuntu in all four shells
  (`.github/workflows/tests.yml`); don't merge a PR until it's green. A change to behaviour comes with a test, and a bug fix with the
  test that would have caught it.
- **Don't run anything that changes a real cluster** (cancel, delete) unless
  the user explicitly asks for that run. Against real clusters use
  `--dry-run`; exercise the paths that make changes against the mock.
- Keep the README's command table, `--help`, and the comment at the top of
  each script in step with behaviour.

## Conventions

- **POSIX `sh` only.** No `local`, `[[ ]]`, arrays, `function`, `echo -e`,
  `sed -i`, `readlink -f`, `grep -P`, `date -d`, process substitution, or
  `pipefail`. Prefix function-private variables instead of `local`
  (`_crv_id` in `camunda_resolve_versions`).
- **Every script and library file** starts with the shebang (or
  `# shellcheck shell=sh`), then `# SPDX-License-Identifier: MIT` and
  `# Copyright (c) 2026 BP3 Global Inc.`
- **Commands** are `c8sh NOUN VERB` (`c8sh instance cancel`), in
  `libexec/c8sh/NOUN-VERB`. The header comment's first line must be
  `# c8sh NOUN VERB - what it does`: `c8sh --help` shows it. Name the command
  in usage and messages with `$_camunda_prog`, never `$0`. Don't name
  anything `c8`: Camunda's own CLI installs a `c8` command (an optional `c8`
  symlink to `c8sh` is documented, with that warning).
- `c8sh` passes `-c`/`-e` given before the noun as `C8SH_CUSTOMER`/`C8SH_ENV`,
  the name to show as `C8SH_PROG`, and runs the command in `C8SH_SHELL`
  (default `/bin/sh`; the tests set it to the shell under test).
- **Options come before operands.** Parse them with a `while`/`case` loop
  (not `getopts`: no long options). Script options come first, then
  `camunda_common_option` handles `-c/--customer`, `-e/--environment-name`,
  `-h/--help` and rejects unknown ones. Commands that change things have
  `-n/--dry-run` and `-y/--yes`.
- **Output:** stdout is plain data, one item per line, for piping (e.g.
  `processDefinitionId version`); summaries, warnings and errors go to
  stderr. Commands that take versions read the same pairs from stdin.
- **Exit status:** 0 success; 1 failure, or something skipped or not found;
  2 usage error, reported before any API call.
- **Messages name where they apply:** use `$CAMUNDA_LABEL`
  (`customer/env`), never `$CAMUNDA_ENV` alone.

## Safety rules the code relies on

- Never send a batch filter without a key: an empty filter matches every
  instance in the cluster. Batches filter on exactly one
  `processDefinitionKey`, or on exact `processInstanceKey`s.
- Call `camunda_check_keys` on everything before `camunda_confirm` and
  before the first request: a key also goes into URL paths.
- `camunda_confirm` before any change. It reads the answer from
  `CAMUNDA_TTY` (default `/dev/tty`), not stdin, which may be a pipe.
- Secrets never go on a command line (`ps` can see them): `camunda_api`
  passes them to curl in a private config file. Never print them.
- Profiles are parsed, never sourced or `eval`ed. A profile can't set
  `CAMUNDA_ENV`, `CAMUNDA_CUSTOMER`, `CAMUNDA_CONFIG_DIR`, `CAMUNDA_TMPDIR`
  or `CAMUNDA_TTY`.

## Shell pitfalls we've hit

- `VAR=x func` (a prefix assignment on a function call) can leave `VAR` set
  afterwards in dash. Set and export it in a subshell instead:
  `(VAR=x && export VAR && run ...)`.
- `camunda_die` inside `$(...)` only exits that subshell, and a pipeline's
  status is its last command's. Write results to files in `$CAMUNDA_TMPDIR`
  and check the function's status.
- awk's `NR == FNR` idiom breaks when the first file is empty; read the
  lookup file in `BEGIN` with `getline` instead.
- zsh doesn't word-split unquoted variables, so a test loop over
  `sh="bash --posix"` breaks if the loop itself runs in zsh. `tests/run.sh`
  is `sh`, and uses `$TEST_SHELL` unquoted on purpose.
- Redirecting stdin doesn't take away the terminal: a `/dev/tty` prompt
  still appears. Tests set `CAMUNDA_TTY` instead.
- `<` and `>` in version selectors must be quoted in the shell; the word
  forms (`older than 50`) needn't be.
- Windows checkouts can turn `\n` into `\r\n` (`.gitattributes` prevents it
  for the repository); files users edit, like profiles and `.current`, are
  read with a trailing `\r` dropped.

## Camunda API facts that aren't obvious

- Searches are `POST .../search` with cursor paging (`page.after`,
  `page.endCursor`); `page.limit` is at most 10000. Keys are strings.
- Unknown filter fields are rejected with 400 ("cannot be parsed"), and so
  are operators some fields don't support: a process definition's `version`
  takes only an exact number (`"version": 339`), not `$eq`, `$in` or `$gte`.
  (The mock accepts operators on every field.)
- With `isLatestVersion: true`, sorting is only by `processDefinitionId` or
  `tenantId`, so sort by name locally.
- `$in` lists of 10000 keys are accepted; the scripts send up to 1000.
- Batch cancellation (`/process-instances/cancellation`) cancels **active
  root** instances only, whatever the filter says; the engine then ends what
  they called.
- Batch deletion (`/process-instances/deletion`, 8.9+) deletes finished
  instances; send the `COMPLETED`/`TERMINATED` state filter explicitly.
- Deleting a process version (`/resources/{key}/deletion`) with active
  instances puts it in `DRAINING`, it doesn't fail. Its record stays, as
  `DELETED`, until its history is deleted too (`deleteHistory: true`,
  8.9+; asking again for a `DELETED` version purges its history).
- Process definitions have a `state` (`ACTIVE`/`DRAINING`/`DELETED`) from
  8.9.14; older clusters don't report it, so treat missing as `ACTIVE`.
- `/process-definitions/statistics/process-instances-by-version` (8.9+)
  takes one `processDefinitionId` per request and returns only versions
  with active instances.
- Permissions: listing needs `PROCESS_DEFINITION` read permissions;
  cancelling and deleting instances need the matching `PROCESS_DEFINITION`
  permissions; deleting versions needs `RESOURCE` → `DELETE_PROCESS`. A 403
  names the permission and resource it needs.

## Tests

- `tests/run.sh` runs each `test_*.sh` in dash, `bash --posix`,
  `zsh --emulate sh` and BusyBox `sh` (whichever are installed), 4 files at
  a time (`TEST_JOBS`), against `tests/mock_camunda.py`. Each test gets
  fresh profiles, cache, `HOME` and request log, and no terminal.
- A test file sets `fixture=` (and `profiles=flat` or `customers`) and
  defines `test_*` functions using `run`, `run_with`, `c8`, `lib`, `answer`
  and the `assert_*` helpers documented in `tests/lib.sh`. `assert_sent`
  checks what reached the mock, as a grep on its JSON request log.
- The mock never changes its data; tests check what was sent. Add data to
  `tests/fixtures/basic.json` (or a new fixture), keeping the comment that
  says what each instance is for.
- Most failures so far were in the tests, not the scripts. Before trusting
  a new test, make sure it can fail: e.g. a confirmation test needs a
  version with no active instances, or it never reaches the prompt; a
  version selector after a process id swallows every later operand.
