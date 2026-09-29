# Camunda Shell Utilities

[![tests](https://github.com/BP3/camunda-shell-utils/actions/workflows/tests.yml/badge.svg)](https://github.com/BP3/camunda-shell-utils/actions/workflows/tests.yml)

Shell scripts for the [Camunda 8 Orchestration API](https://docs.camunda.io/docs/apis-tools/orchestration-cluster-api-rest/orchestration-cluster-api-rest-overview/),
written in plain POSIX `sh` with `curl`. They work in bash, zsh, dash and
other POSIX shells, against both Camunda SaaS and self-managed clusters.

## Requirements

- `curl`
- `jq`: needed by most commands, and used to pretty-print responses in a terminal

## Setup

On Windows, use WSL (Windows Subsystem for Linux), and clone the repository
from inside WSL, into your Linux home directory (e.g. `~/workspace`), rather
than under `/mnt/c`. The scripts run faster there, and file permissions
behave as on Linux.

1. Put `bin/` on your `PATH`, or link `c8sh` into a directory that's
   already on it:

   ```sh
   ln -s "$PWD/bin/c8sh" ~/bin/
   ```

   If you'd like to type `c8` instead, link it under that name too:
   `ln -s "$PWD/bin/c8sh" ~/bin/c8`. Only do this if you don't use
   Camunda's own CLI (`c8ctl`), which also installs a `c8` command:
   whichever comes first on your `PATH` would win.

2. Create a folder per customer in `~/.config/camunda/`, with one profile
   per environment, starting from the examples in [`profiles/`](profiles/):

   ```sh
   mkdir -p ~/.config/camunda/acme
   cp profiles/common.env.example          ~/.config/camunda/common.env
   cp profiles/customer-common.env.example ~/.config/camunda/acme/common.env
   cp profiles/saas.env.example            ~/.config/camunda/acme/dev.env   # then sit, uat, prod ...
   chmod 600 ~/.config/camunda/common.env ~/.config/camunda/*/*.env
   ```

   Then set the customer's region in `acme/common.env`, and fill in each
   environment's cluster ID and client credentials.

3. Choose the customer and environment, and check that it works:

   ```sh
   c8sh profile use acme dev
   c8sh cluster topology
   ```

## Customers, environments and profiles

Profiles live in `~/.config/camunda/`, with a folder per customer and a file
per environment:

```
~/.config/camunda/
  common.env            # shared by every customer (e.g. SaaS token URL)
  acme/
    common.env          # shared by acme's environments (e.g. SaaS region)
    dev.env  sit.env  uat.env  prod.env
  globex/
    dev.env  prod.env
```

If you only work with one set of environments, you can skip the customer
folders and put the `<env>.env` files directly in `~/.config/camunda/`.

### Choosing which one to use

Each command uses the first of these that's set:

1. **Options:** `-c`/`--customer NAME` and `-e`/`--environment-name ENV`
2. **Shell variables:** `CAMUNDA_CUSTOMER` and `CAMUNDA_ENV`
3. **The saved default:** set with `c8sh profile use`

If no environment is chosen, the command stops rather than guessing. A saved
environment only applies together with the saved customer: pointing one
shell at another customer never carries a `prod` across.

`c8sh profile` shows and switches profiles:

```sh
c8sh profile                  # what's in effect, where each choice came from, and its settings
c8sh profile list             # every customer/environment; '*' marks the one in effect
c8sh profile use acme dev     # save a default for every terminal (also: c8sh profile use acme/dev)
c8sh profile clear            # forget the saved default
```

The saved default is shared by all your terminals. To work with a different
customer or environment in one terminal only, set the shell variables there,
or use `-c`/`-e` for a single command:

```sh
export CAMUNDA_CUSTOMER=globex CAMUNDA_ENV=uat   # this terminal only
c8sh process list -c acme -e prod                # this command only
```

In a pipeline, `-c`/`-e` and a prefix assignment such as
`CAMUNDA_ENV=uat c8sh process list | ...` apply only to the command they're
given to. Everything after the `|` uses whatever else is in effect, so
either give each command its own options or `export` the variables:

```sh
c8sh process list -e uat | grep PATTERN | c8sh version list -e uat
```

### Showing the profile in your prompt

`c8sh profile prompt` prints the customer and environment in effect, e.g.
`acme/prod`, or nothing. Put it in your shell prompt, so you can always see
where your next command will go:

```sh
# zsh (~/.zshrc)
setopt PROMPT_SUBST
PROMPT='[$(c8sh profile prompt)] '$PROMPT

# bash (~/.bashrc)
PS1='[$(c8sh profile prompt)] '$PS1
```

### Settings

Settings are loaded in this order, and later sources override earlier ones:

| Source | Purpose |
|---|---|
| `~/.config/camunda/common.env` | shared by every customer, e.g. SaaS token URL (optional) |
| `~/.config/camunda/<customer>/common.env` | shared by the customer's environments, e.g. SaaS region, SaaS or self-managed (optional) |
| `~/.config/camunda/<customer>/<env>.env` | one per environment: cluster, credentials |
| exported `CAMUNDA_*` variables | one-off overrides, CI (a warning shows what was overridden) |

Profiles are *parsed*, not sourced. Only `CAMUNDA_*` lines are read, and
nothing in them is run or expanded. Files that use `export KEY='value'` work
unchanged. The full list of settings is at the top of
[`lib/camunda.sh`](lib/camunda.sh).

- **SaaS** needs only `CAMUNDA_CLUSTER_REGION`, `CAMUNDA_CLUSTER_ID`,
  `CAMUNDA_CLIENT_ID` and `CAMUNDA_CLIENT_SECRET`. The REST address, token URL
  and audience are derived from these.
- **Self-managed** sets `CAMUNDA_CLIENT_MODE='self-managed'`,
  `CAMUNDA_REST_ADDRESS`, and an auth strategy: `oauth` (Keycloak, Entra or
  another OIDC provider), `basic` or `none`. See
  [`profiles/self-managed.env.example`](profiles/self-managed.env.example).

Use `CAMUNDA_CONFIG_DIR` to keep profiles somewhere else.

## Credentials and safety

- **OAuth tokens** are cached per environment in
  `${XDG_CACHE_HOME:-~/.cache}/camunda/`, with owner-only permissions, until a
  minute before they expire.
- **Secrets stay off the command line**, where `ps` could show them. They're
  passed to curl through a temporary config file that only you can read.
- **File permissions:** you get a warning if a profile is readable by other
  users.
- **Confirmation:** commands that change anything ask you to type the
  customer and environment (e.g. `acme/prod`) before going ahead, in every
  environment. `-y`/`--yes`
  skips the prompt for one command. Set `CAMUNDA_PROTECTED='false'` in a
  profile to stop the prompts for that environment. Without a terminal
  (e.g. in CI), a command that would ask stops instead, unless given `-y`
  or run where `CAMUNDA_PROTECTED` is `'false'`.

## Commands

Everything is one command, `c8sh`, followed by what to act on and what to do:
`c8sh NOUN VERB`, like `git` or `kubectl`. `c8sh --help` lists every command,
`c8sh instance --help` a noun's verbs, and `c8sh instance cancel --help` (or
`c8sh help instance cancel`) a command's options. `-c` and `-e` can come
before the noun (`c8sh -e prod instance cancel ...`) or after the verb.

| Command | Description |
|---|---|
| `c8sh profile` | Show, list and switch customer and environment profiles; `c8sh profile prompt` for your shell prompt |
| `c8sh cluster topology` | Show brokers, partitions and version, a quick way to check a profile |
| `c8sh process list` | List deployed processes as `"Process Name" processDefinitionId` |
| `c8sh version list` | List each version of the named or piped-in processes as `processDefinitionId version`; `--deleted` lists deleted versions instead |
| `c8sh instance cancel` | Cancel the active instances of the named or piped-in process versions, as whole call trees: each root ends with every instance it called; `-n`/`--dry-run` lists them instead |
| `c8sh instance delete` | Delete the history of finished (completed or terminated) instances of the named or piped-in process versions, as whole call trees: each root with every instance it called, and never a called instance whose parent stays (`--ignore-dependencies` turns this off); `-n`/`--dry-run` lists them instead |
| `c8sh version delete` | Delete the named or piped-in process versions; versions with active instances are skipped unless `--allow-active`, and `--delete-history` also removes their history (8.9+); `-n`/`--dry-run` lists them instead |

The output is plain text, one item per line, so the commands combine with
each other and with standard tools:

```sh
c8sh process list | grep PATTERN | c8sh version list
```

(with a customer and environment chosen, as in
[Customers, environments and profiles](#customers-environments-and-profiles)).

Commands that change things have a `-n`/`--dry-run` option, which shows
what they would do without changing anything. Try that first:

```sh
c8sh version list PROCESS_ID | c8sh instance cancel --dry-run
```

When you name a process on the command line, the commands that act on
process versions let you pick them with ranges and phrases instead of
listing numbers. `--help` has the full list:

```sh
c8sh instance cancel --dry-run PROCESS_ID oldest 10
c8sh instance cancel --dry-run PROCESS_ID 27-100
c8sh instance cancel --dry-run PROCESS_ID older than 600
c8sh instance cancel --dry-run PROCESS_ID all but newest 5
```

A typical clean-up of old versions runs in three steps, each tried with
`--dry-run` first:

```sh
c8sh instance cancel PROCESS_ID all but newest 5   # stop what's still running
c8sh instance delete PROCESS_ID all but newest 5   # remove their history
c8sh version delete PROCESS_ID all but newest 5    # remove the versions
```

A deleted version is gone from the engine, but Camunda keeps its record,
and its history, until that history is deleted too. The commands leave
deleted versions out (Camunda 8.9.14 and later say which they are).
`c8sh version list --deleted` lists them, e.g. to purge their
history later:

```sh
c8sh version list --deleted PROCESS_ID | c8sh version delete --delete-history
```

### The old command names

Until recently, each command had its own name, such as `c8-list-processes`.
Those names still work, printing a note of the new name, but they will be
removed:

| Old | New |
|---|---|
| `c8-profile` | `c8sh profile` |
| `c8-topology` | `c8sh cluster topology` |
| `c8-list-processes` | `c8sh process list` |
| `c8-list-process-versions` | `c8sh version list` |
| `c8-cancel-process-instances` | `c8sh instance cancel` |
| `c8-delete-process-instances` | `c8sh instance delete` |
| `c8-delete-process-versions` | `c8sh version delete` |

## Running the tests

```sh
tests/run.sh                          # every test, in every POSIX shell installed
tests/run.sh tests/test_profiles.sh   # one file
TEST_SHELLS='dash' tests/run.sh       # one shell (separate several with ';')
TEST_JOBS=2 tests/run.sh              # test files run 4 at a time by default
```

The tests run each command in dash, `bash --posix`, `zsh --emulate sh` and
BusyBox `sh`, whichever are installed (the runner says which it skips),
against a mock Camunda API (`tests/mock_camunda.py`, which needs Python 3).
They never touch a real cluster, never prompt, and use their own config,
cache and `HOME`, so your profiles and tokens are safe. Tests check what
each command printed and exited with, and what it sent to the mock.

GitHub runs the same suite on Ubuntu, in all four shells, for every pull
request and every push to `main` ([`.github/workflows/tests.yml`](.github/workflows/tests.yml)).
It also runs shellcheck, which must report no warnings.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how the commands are put
together, adding a command (with a worked example), and writing its tests.

## License

[MIT](LICENSE) © BP3 Global Inc.
