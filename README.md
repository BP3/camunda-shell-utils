# Camunda Shell Utilities

Shell scripts for the [Camunda 8 Orchestration API](https://docs.camunda.io/docs/apis-tools/orchestration-cluster-api-rest/orchestration-cluster-api-rest-overview/),
written in plain POSIX `sh` with `curl`. They work in bash, zsh, dash and
other POSIX shells, against both Camunda SaaS and self-managed clusters.

## Requirements

- `curl`
- `jq`: needed by the `list-*` scripts, and used to pretty-print responses in a terminal

## Setup

On Windows, use WSL (Windows Subsystem for Linux), and clone the repository
from inside WSL, into your Linux home directory (e.g. `~/workspace`), rather
than under `/mnt/c`. The scripts run faster there, and file permissions
behave as on Linux.

1. Put `bin/` on your `PATH`, or symlink the scripts you want into a directory
   that's already on it:

   ```sh
   ln -s "$PWD/bin/c8-topology" ~/bin/
   ```

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
   c8-profile use acme dev
   c8-topology
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

Each script uses the first of these that's set:

1. **Options:** `-c`/`--customer NAME` and `-e`/`--environment-name ENV`
2. **Shell variables:** `CAMUNDA_CUSTOMER` and `CAMUNDA_ENV`
3. **The saved default:** set with `c8-profile use`

If no environment is chosen, the script stops rather than guessing. A saved
environment only applies together with the saved customer: pointing one
shell at another customer never carries a `prod` across.

`c8-profile` shows and switches profiles:

```sh
c8-profile                  # what's in effect, where each choice came from, and its settings
c8-profile list             # every customer/environment; '*' marks the one in effect
c8-profile use acme dev     # save a default for every terminal (also: c8-profile use acme/dev)
c8-profile clear            # forget the saved default
```

The saved default is shared by all your terminals. To work with a different
customer or environment in one terminal only, set the shell variables there,
or use `-c`/`-e` for a single command:

```sh
export CAMUNDA_CUSTOMER=globex CAMUNDA_ENV=uat   # this terminal only
c8-list-processes -c acme -e prod                # this command only
```

In a pipeline, `-c`/`-e` and a prefix assignment such as
`CAMUNDA_ENV=uat c8-list-processes | ...` apply only to the command they're
given to. Everything after the `|` uses whatever else is in effect, so
either give each command its own options or `export` the variables:

```sh
c8-list-processes -e uat | grep PATTERN | c8-list-process-versions -e uat
```

### Showing the profile in your prompt

`c8-profile prompt` prints the customer and environment in effect, e.g.
`acme/prod`, or nothing. Put it in your shell prompt, so you can always see
where your next command will go:

```sh
# zsh (~/.zshrc)
setopt PROMPT_SUBST
PROMPT='[$(c8-profile prompt)] '$PROMPT

# bash (~/.bashrc)
PS1='[$(c8-profile prompt)] '$PS1
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
- **Confirmation:** scripts that change anything ask you to type the
  customer and environment (e.g. `acme/prod`) before going ahead, in every
  environment. `-y`/`--yes`
  skips the prompt for one command. Set `CAMUNDA_PROTECTED='false'` in a
  profile to stop the prompts for that environment. Without a terminal
  (e.g. in CI), a script that would ask stops instead, unless given `-y`
  or run where `CAMUNDA_PROTECTED` is `'false'`.

## Scripts

Every script is named `c8-*` (for Camunda 8), so `c8-<Tab>` lists them all.
Each takes short and long options; `--help` describes them.

| Script | Description |
|---|---|
| `c8-profile` | Show, list and switch customer and environment profiles; `c8-profile prompt` for your shell prompt |
| `c8-topology` | Show brokers, partitions and version, a quick way to check a profile |
| `c8-list-processes` | List deployed processes as `"Process Name" processDefinitionId` |
| `c8-list-process-versions` | List each version of the named or piped-in processes as `processDefinitionId version`; `--deleted` lists deleted versions instead |
| `c8-cancel-process-instances` | Cancel the active instances of the named or piped-in process versions, as whole call trees: each root ends with every instance it called; `-n`/`--dry-run` lists them instead |
| `c8-delete-process-instances` | Delete the history of finished (completed or terminated) instances of the named or piped-in process versions, as whole call trees: each root with every instance it called, and never a called instance whose parent stays (`--ignore-dependencies` turns this off); `-n`/`--dry-run` lists them instead |
| `c8-delete-process-versions` | Delete the named or piped-in process versions; versions with active instances are skipped unless `--allow-active`, and `--delete-history` also removes their history (8.9+); `-n`/`--dry-run` lists them instead |

The output is plain text, one item per line, so the scripts combine with each
other and with standard tools:

```sh
c8-list-processes | grep PATTERN | c8-list-process-versions
```

(with a customer and environment chosen, as in
[Customers, environments and profiles](#customers-environments-and-profiles)).

Scripts that change things have a `-n`/`--dry-run` option, which shows
what they would do without changing anything. Try that first:

```sh
c8-list-process-versions PROCESS_ID | c8-cancel-process-instances --dry-run
```

When you name a process on the command line, the scripts that act on
process versions let you pick them with ranges and phrases instead of
listing numbers. `--help` has the full list:

```sh
c8-cancel-process-instances --dry-run PROCESS_ID oldest 10
c8-cancel-process-instances --dry-run PROCESS_ID 27-100
c8-cancel-process-instances --dry-run PROCESS_ID older than 600
c8-cancel-process-instances --dry-run PROCESS_ID all but newest 5
```

A typical clean-up of old versions runs in three steps, each tried with
`--dry-run` first:

```sh
c8-cancel-process-instances PROCESS_ID all but newest 5   # stop what's still running
c8-delete-process-instances PROCESS_ID all but newest 5   # remove their history
c8-delete-process-versions PROCESS_ID all but newest 5    # remove the versions
```

A deleted version is gone from the engine, but Camunda keeps its record,
and its history, until that history is deleted too. The scripts leave
deleted versions out (Camunda 8.9.14 and later say which they are).
`c8-list-process-versions --deleted` lists them, e.g. to purge their
history later:

```sh
c8-list-process-versions --deleted PROCESS_ID | c8-delete-process-versions --delete-history
```

## Writing a script

Scripts source [`lib/camunda.sh`](lib/camunda.sh), parse their options,
load a profile, and call the API. [`bin/c8-topology`](bin/c8-topology)
is the minimal template. Start each new file with the same license header:

```sh
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 BP3 Global Inc.
```

Options are parsed with a plain `while`/`case` loop, since `getopts` has no
long options. The script's own options come first. `camunda_common_option`
handles the shared ones (`-c`/`--customer`, `-e`/`--environment-name`, `-h`/`--help`, which calls
the script's `usage` function) and rejects unknown options:

```sh
while [ $# -gt 0 ]; do
    case $1 in
        -n | --dry-run) dry_run=1; shift ;;
        --) shift; break ;;
        -?*) camunda_common_option "$@"; shift "$_camunda_shift" ;;
        *) break ;;
    esac
done
```

Then:

```sh
camunda_load_profile                          # uses -c/-e, the shell variables, or the saved default
camunda_api GET /topology                     # path is relative to /v2

camunda_api POST /process-instances/search --data @query.json
camunda_search /process-definitions/search '{"filter":{}}' # all pages, one item per line
camunda_confirm "cancel 12 process instances" # before any change
```

## License

[MIT](LICENSE) © BP3 Global Inc.
