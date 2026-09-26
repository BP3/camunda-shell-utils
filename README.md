# Camunda Shell Utilities

Shell scripts for the [Camunda 8 Orchestration API](https://docs.camunda.io/docs/apis-tools/orchestration-cluster-api-rest/orchestration-cluster-api-rest-overview/),
written in plain POSIX `sh` with `curl`. They work in bash, zsh, dash and
other POSIX shells, against both Camunda SaaS and self-managed clusters.

## Requirements

- `curl`
- `jq`: needed by the `list-*` scripts, and used to pretty-print responses in a terminal

## Setup

1. Put `bin/` on your `PATH`, or symlink the scripts you want into a directory
   that's already on it:

   ```sh
   ln -s "$PWD/bin/c8-topology" ~/bin/
   ```

2. Create one profile per environment in `~/.config/camunda/`, starting from
   the examples in [`profiles/`](profiles/):

   ```sh
   mkdir -p ~/.config/camunda
   cp profiles/common.env.example ~/.config/camunda/common.env
   cp profiles/saas.env.example   ~/.config/camunda/dev.env   # then sit, uat, prod ...
   chmod 600 ~/.config/camunda/*.env
   ```

   Then fill in each environment's cluster ID and client credentials.

3. Check that it works:

   ```sh
   c8-topology -e dev
   ```

## Environments and profiles

Every script takes `-e ENV` or `--environment-name ENV`, or falls back to
`$CAMUNDA_ENV`. If neither is set, the script stops rather than guessing.

Usually you work in one environment for a while, so set it once for the
shell session and leave it out of each command:

```sh
export CAMUNDA_ENV=dev
c8-list-processes | grep PATTERN | c8-list-process-versions
```

Use `-e` for a one-off command against a different environment. It takes
precedence over `CAMUNDA_ENV`:

```sh
c8-list-processes -e uat
```

In a pipeline, `-e` applies only to the command it's given to, so each
command needs its own:

```sh
c8-list-processes -e uat | grep PATTERN | c8-list-process-versions -e uat
```

The same goes for a prefix assignment: `CAMUNDA_ENV=uat c8-list-processes | ...`
only sets the environment for the first command. Everything after the `|`
would still use your exported value, or stop if there isn't one.

Settings are loaded in this order, and later sources override earlier ones:

| Source | Purpose |
|---|---|
| `~/.config/camunda/common.env` | shared values, e.g. SaaS region (optional) |
| `~/.config/camunda/<env>.env` | one per environment: cluster, credentials |
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
  environment name before going ahead, in every environment. `-y`/`--yes`
  skips the prompt for one command. Set `CAMUNDA_PROTECTED='false'` in a
  profile to stop the prompts for that environment. Without a terminal
  (e.g. in CI), a script that would ask stops instead, unless given `-y`
  or run where `CAMUNDA_PROTECTED` is `'false'`.

## Scripts

Every script is named `c8-*` (for Camunda 8), so `c8-<Tab>` lists them all.
Each takes short and long options; `--help` describes them.

| Script | Description |
|---|---|
| `c8-topology` | Show brokers, partitions and version, a quick way to check a profile |
| `c8-list-processes` | List deployed processes as `"Process Name" processDefinitionId` |
| `c8-list-process-versions` | List each version of the named or piped-in processes as `processDefinitionId version` |
| `c8-cancel-process-instances` | Cancel the active instances of the named or piped-in process versions; `-n`/`--dry-run` lists them instead |
| `c8-delete-process-instances` | Delete the history of finished (completed or terminated) instances of the named or piped-in process versions, as whole call trees: each root with every instance it called, and never a called instance whose parent stays (`--ignore-dependencies` turns this off); `-n`/`--dry-run` lists them instead |

The output is plain text, one item per line, so the scripts combine with each
other and with standard tools:

```sh
c8-list-processes | grep PATTERN | c8-list-process-versions
```

(with `CAMUNDA_ENV` exported, as in
[Environments and profiles](#environments-and-profiles)).

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
handles the shared ones (`-e`/`--environment-name`, `-h`/`--help`, which calls
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
camunda_load_profile                          # uses -e, or $CAMUNDA_ENV
camunda_api GET /topology                     # path is relative to /v2

camunda_api POST /process-instances/search --data @query.json
camunda_search /process-definitions/search '{"filter":{}}' # all pages, one item per line
camunda_confirm "cancel 12 process instances" # before any change
```

## License

[MIT](LICENSE) © BP3 Global Inc.
