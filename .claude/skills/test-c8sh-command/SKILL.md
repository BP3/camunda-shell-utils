---
name: test-c8sh-command
description: Write or extend tests for a c8sh command in this repository, against the mock Camunda API, and make sure they can fail. Use when asked to test a command, add test cases or mock data, or fix a failing test in tests/.
---

# Testing a c8sh command

The helpers are documented at the top of `tests/lib.sh`, and "Writing tests"
in `CONTRIBUTING.md` walks through an example. This skill is what to cover,
and how to know the tests mean something.

## 1. Know the data

Read the comments in `tests/fixtures/basic.json` and at the top of the test
files: each process and instance is there for a reason (call trees, orphans,
deleted and draining versions, malformed keys, a refused deletion). Reuse
them where you can.

If you add data, give it an `_about`. Then check the tests that list
everything (`tests/test_list.sh`): a new process changes their expected
output.

## 2. Write the tests

Put them in `tests/test_<noun>_<verb>.sh` (or the file for that noun), with
`fixture=basic`, and `profiles=customers` if the layout matters. For every
command, cover:

- **What it prints and exits with** for the normal case (`assert_stdout`,
  `assert_status`), and the messages that matter (`assert_stderr_has`).
- **What it sends** (`assert_sent PATTERN N`, `assert_not_sent`): exact
  counts, and that every request is scoped the way the safety rules say.
- **Mistakes:** unknown or undeployed versions (status 1), bad operands and
  options (status 2, before any request).

For a command that changes things, also:

- `--dry-run` lists what would change and sends nothing.
- The real path against the mock: exactly the requests expected.
- Confirmation: refused with no terminal (`-e prod`), a wrong `answer`
  aborts, the right `answer` goes ahead, `-y` skips it. Nothing is sent
  before it's confirmed.
- A malformed key stops everything, including versions listed before it.
- Deleted and draining versions, where they apply.

## 3. Make sure each test can fail

Before trusting a test, see it fail:

- Change an expected line and check the test fails. (Check the change took:
  a `sed` whose pattern doesn't match changes nothing, and the test "passes".)
- For behaviour, break the code in a copy, never in place:
  ```sh
  T=$(mktemp -d) && cp -R bin lib libexec tests "$T/"
  # edit $T/libexec/c8sh/..., then:
  TEST_SHELLS=dash "$T/tests/run.sh" "$T/tests/test_x.sh"; rm -rf "$T"
  ```

Tests here have passed for the wrong reason before:

- A confirmation test used a version with active instances, so the command
  stopped before it asked.
- A version selector after a process id swallowed the operands meant as a
  second process: pipe `id version` pairs in instead.
- `VAR=x run ...` left `VAR` set afterwards in dash: use
  `(VAR=x && export VAR && run ...)`.

## 4. Run them

```sh
TEST_SHELLS=dash tests/run.sh tests/test_x.sh   # while working
tests/run.sh                                     # before committing
```

To match CI, including BusyBox, run the suite on Ubuntu too, if Docker is
running (the command is in `CONTRIBUTING.md`).

When a test fails, work out whether the test or the command is wrong. Most
failures so far were in the tests. Say which it was when you report back.
