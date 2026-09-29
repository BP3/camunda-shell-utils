---
name: add-c8sh-command
description: Add a new c8sh command (c8sh NOUN VERB) to this repository, or a new verb to an existing noun. Use when asked to add, create or write a command, subcommand or verb for c8sh, or to wrap a new Camunda Orchestration API endpoint.
---

# Adding a c8sh command

Read `CONTRIBUTING.md` (how a command is put together, the library by task,
the worked example) and `CLAUDE.md` (conventions, safety rules, pitfalls, API
facts) before writing anything. This skill is the order to do things in.

## 1. Start clean

```sh
git fetch --prune origin && git switch main && git pull --ff-only
git switch -c feature/<noun>-<verb>
```

## 2. Pin down what the command is

- **Name:** `c8sh NOUN VERB`. Run `bin/c8sh --help` to see the existing
  nouns and reuse one if it fits. A new noun is a naming decision: check it
  with the user first. Never use `c8` as a name.
- **What it prints on stdout**, one item per line, in a form the next
  command can read (e.g. `processDefinitionId version`). Messages go to
  stderr.
- **Whether it changes anything.** If it does, it needs `-n/--dry-run`,
  `-y/--yes`, `camunda_check_keys` and `camunda_confirm`, and every rule in
  "Safety rules the code relies on" in `CLAUDE.md`.

## 3. Check the API before relying on it

- Read the endpoint in Camunda's OpenAPI spec, for the version the user's
  clusters run: `https://raw.githubusercontent.com/camunda/camunda/stable/8.9/zeebe/gateway-protocol/src/main/proto/v2/`
  (`process-definitions.yaml`, `process-instances.yaml`, `batch-operations.yaml`, ...).
  Note the version it was added in (`x-added-in-version`).
- Where behaviour matters and the spec is vague, try it **read-only** on a
  real environment (a search, never a change), e.g. with
  `dash -c '. lib/camunda.sh; camunda_load_profile; camunda_api POST ...'`.
  Never send anything that changes a real cluster unless the user asks for
  that exact run.
- Add anything surprising to "Camunda API facts" in `CLAUDE.md`.

## 4. Write it

- Copy the closest existing command in `libexec/c8sh/`:
  `cluster-topology` (one call), `version-list` (ids from arguments or
  stdin), `instance-cancel` (version selectors, changes, confirmation).
- Save it as `libexec/c8sh/NOUN-VERB`, `chmod +x` it. Its header's first
  line must be `# c8sh NOUN VERB - what it does`: `c8sh --help` shows it.
- Use `$_camunda_prog` in usage and messages, and `$CAMUNDA_LABEL` for where
  it applies. Parse options with the `while`/`case` loop and
  `camunda_common_option`. Check operands before `camunda_load_profile`.
- Use the library rather than new code: `camunda_search` for paging,
  `camunda_resolve_versions` for versions, `camunda_find_instances`,
  `camunda_run_batches`, and so on (the table in `CONTRIBUTING.md`).

## 5. Test it

Use the `test-c8sh-command` skill. Don't move on until the new tests pass,
and have been seen to fail when the command is broken.

## 6. Document it

- The README's command table (and an example if it's worth one).
- `--help` and the header comment, which must say the same as the code does.
- `CLAUDE.md`, if you learned a pitfall or an API fact.

## 7. Check and hand over

```sh
tests/run.sh
docker run --rm -v "$PWD":/mnt:ro -w /mnt koalaman/shellcheck:v0.9.0 \
    --shell=sh --severity=warning bin/* libexec/c8sh/* lib/camunda.sh tests/*.sh
```

(If Docker isn't running, `shellcheck` itself, if installed, or leave it to
CI.) Look through the diff for anything real: client ids, secrets, cluster
ids, customer names. Commit, push, and open a pull request, or give the user
its title and description if they open pull requests themselves. CI must be
green before it merges.
