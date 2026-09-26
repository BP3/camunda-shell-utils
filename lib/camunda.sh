# shellcheck shell=sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 BP3 Global Inc.
#
# camunda.sh - shared helpers for the Camunda Orchestration API scripts
# =====================================================================
#
# Source this file from a script, then call camunda_load_profile and
# camunda_api. Plain POSIX sh; needs curl, and uses jq for pretty output
# when it is installed.
#
# Profiles
# --------
# Settings are read from $CAMUNDA_CONFIG_DIR (default
# ${XDG_CONFIG_HOME:-$HOME/.config}/camunda), later sources winning:
#
#   1. common.env    optional; values shared by every environment
#   2. <env>.env     required; one file per environment (dev, sit, uat, ...)
#   3. environment   any CAMUNDA_* variable already exported in the shell
#
# Profiles are parsed, never sourced: only CAMUNDA_* assignments are read,
# and nothing in them is executed or expanded. An optional leading 'export'
# and single or double quotes are accepted, so existing files work as-is.
#
# Settings
# --------
#   CAMUNDA_CLIENT_MODE          saas (default) | self-managed
#   CAMUNDA_REST_ADDRESS         cluster REST address; derived for SaaS from
#                                region + cluster id, required otherwise
#   CAMUNDA_CLUSTER_REGION       SaaS region, e.g. fra-1
#                                (CAMUNDA_CLIENT_CLOUD_REGION also accepted)
#   CAMUNDA_CLUSTER_ID           SaaS cluster id
#   CAMUNDA_AUTH_STRATEGY        oauth (default) | basic | none
#   CAMUNDA_OAUTH_URL            token endpoint (SaaS default provided)
#   CAMUNDA_TOKEN_AUDIENCE       token audience (SaaS default provided)
#   CAMUNDA_TOKEN_SCOPE          token scope, if the identity provider wants one
#   CAMUNDA_CLIENT_ID            OAuth client id
#   CAMUNDA_CLIENT_SECRET        OAuth client secret
#   CAMUNDA_BASIC_AUTH_USERNAME  basic auth user
#   CAMUNDA_BASIC_AUTH_PASSWORD  basic auth password
#   CAMUNDA_PROTECTED            true | false; ask before changing anything
#                                (default: true for 'prod', false otherwise)
#
# Secrets never appear on a command line (where 'ps' could show them): they
# reach curl through a private config file instead.

CAMUNDA_SAAS_OAUTH_URL='https://login.cloud.camunda.io/oauth/token'
CAMUNDA_SAAS_TOKEN_AUDIENCE='zeebe.camunda.io'

# --- messages -----------------------------------------------------------

camunda_die() {
    printf '%s: error: %s\n' "${0##*/}" "$*" >&2
    exit 1
}

camunda_warn() {
    printf '%s: warning: %s\n' "${0##*/}" "$*" >&2
}

# Reports a command-line mistake and exits with status 2.
camunda_usage_error() {
    printf '%s: error: %s\n' "${0##*/}" "$*" >&2
    printf "Try '%s --help' for more information.\n" "${0##*/}" >&2
    exit 2
}

# --- command-line options -----------------------------------------------

# camunda_common_option "$@"
#
# Handles the options every script shares, from the front of "$@":
#
#   -e, --environment-name ENV   sets CAMUNDA_ENV (also -eENV, --environment-name=ENV)
#   -h, --help                   calls the script's usage function and exits
#
# Sets _camunda_shift to how many arguments it used; anything else starting
# with '-' is an error. Scripts put their own options first:
#
#   while [ $# -gt 0 ]; do
#       case $1 in
#           -n | --dry-run) dry_run=1; shift ;;
#           --) shift; break ;;
#           -?*) camunda_common_option "$@"; shift "$_camunda_shift" ;;
#           *) break ;;
#       esac
#   done
camunda_common_option() {
    case $1 in
        -e | --environment-name)
            [ $# -ge 2 ] || camunda_usage_error "option '$1' needs an environment name"
            _cco_env=$2
            _camunda_shift=2
            ;;
        --environment-name=*)
            _cco_env=${1#*=}
            _camunda_shift=1
            ;;
        -e?*)
            _cco_env=${1#-e}
            _camunda_shift=1
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) camunda_usage_error "unknown option '$1'" ;;
    esac
    [ -n "$_cco_env" ] || camunda_usage_error "option '${1%%=*}' needs an environment name"
    CAMUNDA_ENV=$_cco_env
}

# --- temporary files ----------------------------------------------------

# camunda_load_profile creates CAMUNDA_TMPDIR, a private directory for the
# run's temporary files, which scripts may use too.
#
# Removes CAMUNDA_TMPDIR. Installed as an EXIT trap by camunda_load_profile;
# call it yourself if your script replaces that trap.
camunda_cleanup() {
    if [ -n "${CAMUNDA_TMPDIR:-}" ]; then
        rm -rf "$CAMUNDA_TMPDIR"
        CAMUNDA_TMPDIR=
    fi
}

_camunda_init_tmp() {
    CAMUNDA_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/camunda.XXXXXX") ||
        camunda_die "cannot create temporary directory"
    trap camunda_cleanup EXIT
    trap 'camunda_cleanup; exit 130' INT
    trap 'camunda_cleanup; exit 143' TERM
}

# --- profile loading ----------------------------------------------------

# Prints the value escaped for a double-quoted string in a curl config file.
_camunda_cfg_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Warns if a file holding credentials is readable by group or others.
_camunda_check_perms() {
    case $(ls -ld -- "$1" | cut -c5-10) in
        ------) ;;
        *) camunda_warn "$1 is readable by other users; run: chmod 600 '$1'" ;;
    esac
}

# Reads CAMUNDA_* assignments from a profile file into shell variables.
_camunda_read_profile() {
    _crp_file=$1
    _crp_n=0
    _camunda_check_perms "$_crp_file"
    while IFS= read -r _crp_line || [ -n "$_crp_line" ]; do
        _crp_n=$((_crp_n + 1))
        _crp_where="$_crp_file:$_crp_n"

        # Strip leading whitespace and an optional 'export'.
        _crp_line=${_crp_line#"${_crp_line%%[![:space:]]*}"}
        case $_crp_line in
            '' | '#'*) continue ;;
            export[[:space:]]*)
                _crp_line=${_crp_line#export}
                _crp_line=${_crp_line#"${_crp_line%%[![:space:]]*}"}
                ;;
        esac
        case $_crp_line in
            *=*) ;;
            *)
                camunda_warn "$_crp_where: ignoring line that is not KEY=VALUE"
                continue
                ;;
        esac

        _crp_key=${_crp_line%%=*}
        _crp_val=${_crp_line#*=}

        # Only CAMUNDA_* keys are ours; anything else (ZEEBE_*, ...) is
        # left alone for the tools that use it.
        case $_crp_key in
            CAMUNDA_ENV | CAMUNDA_CONFIG_DIR | CAMUNDA_TMPDIR)
                # These choose which profile to read, or belong to the run.
                camunda_warn "$_crp_where: ignoring $_crp_key (set it in the shell instead)"
                continue
                ;;
            CAMUNDA_*) ;;
            *) continue ;;
        esac
        case $_crp_key in
            *[!A-Z0-9_]*)
                camunda_warn "$_crp_where: ignoring invalid name '$_crp_key'"
                continue
                ;;
        esac

        case $_crp_val in
            \'*)
                _crp_val=${_crp_val#\'}
                case $_crp_val in
                    *\'*) _crp_val=${_crp_val%%\'*} ;;
                    *)
                        camunda_warn "$_crp_where: ignoring $_crp_key (missing closing quote)"
                        continue
                        ;;
                esac
                ;;
            \"*)
                _crp_val=${_crp_val#\"}
                case $_crp_val in
                    *\"*) _crp_val=${_crp_val%%\"*} ;;
                    *)
                        camunda_warn "$_crp_where: ignoring $_crp_key (missing closing quote)"
                        continue
                        ;;
                esac
                case $_crp_val in
                    *'$'*) camunda_warn "$_crp_where: \$ in $_crp_key is taken literally, not expanded" ;;
                esac
                ;;
            *)
                # Unquoted: drop a trailing ' # comment' and whitespace.
                _crp_val=${_crp_val%%[[:space:]]#*}
                _crp_val=${_crp_val%"${_crp_val##*[![:space:]]}"}
                ;;
        esac

        # Exported variables win over profiles, but say so: a value left
        # over from sourcing another environment's file is easy to miss.
        case " $_camunda_preset " in
            *" $_crp_key "*)
                camunda_warn "$_crp_key from the environment overrides $_crp_where"
                continue
                ;;
        esac

        eval "$_crp_key=\$_crp_val"
    done <"$_crp_file"
}

# Fails unless each named variable is set and non-empty.
_camunda_require() {
    for _cr_var in "$@"; do
        eval "_cr_val=\${$_cr_var:-}"
        [ -n "$_cr_val" ] ||
            camunda_die "$_cr_var is not set for environment '$CAMUNDA_ENV'"
    done
}

# Lists the environments that have a profile.
camunda_list_envs() {
    for _cle_file in "$_camunda_config_dir"/*.env; do
        [ -f "$_cle_file" ] || continue
        _cle_name=${_cle_file##*/}
        _cle_name=${_cle_name%.env}
        [ "$_cle_name" = common ] || printf '%s\n' "$_cle_name"
    done
}

# camunda_load_profile [ENV]
#
# Loads the profile for ENV (default: $CAMUNDA_ENV, which the -e option of
# camunda_common_option sets), checks it,
# and derives CAMUNDA_API_URL (the /v2 base URL). Call once per script.
camunda_load_profile() {
    CAMUNDA_ENV=${1:-${CAMUNDA_ENV:-}}
    _camunda_config_dir=${CAMUNDA_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/camunda}
    _camunda_cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}/camunda

    if [ -z "$CAMUNDA_ENV" ]; then
        _clp_envs=$(camunda_list_envs | tr '\n' ' ')
        _clp_envs=${_clp_envs% }
        camunda_die "no environment selected: use -e/--environment-name ENV or set CAMUNDA_ENV" \
            "(profiles in $_camunda_config_dir: ${_clp_envs:-none})"
    fi
    case $CAMUNDA_ENV in
        common | *[!A-Za-z0-9_-]*) camunda_die "invalid environment name '$CAMUNDA_ENV'" ;;
    esac

    _clp_profile=$_camunda_config_dir/$CAMUNDA_ENV.env
    [ -f "$_clp_profile" ] ||
        camunda_die "no profile for '$CAMUNDA_ENV': $_clp_profile not found"

    umask 077
    _camunda_init_tmp

    _camunda_preset=$(env | sed -n 's/^\(CAMUNDA_[A-Z0-9_]*\)=.*/\1/p' | tr '\n' ' ')
    if [ -f "$_camunda_config_dir/common.env" ]; then
        _camunda_read_profile "$_camunda_config_dir/common.env"
    fi
    _camunda_read_profile "$_clp_profile"

    # Mode and address.
    case $(printf '%s' "${CAMUNDA_CLIENT_MODE:-saas}" | tr 'A-Z_' 'a-z-') in
        saas) CAMUNDA_CLIENT_MODE=saas ;;
        self-managed | selfmanaged) CAMUNDA_CLIENT_MODE=self-managed ;;
        *) camunda_die "CAMUNDA_CLIENT_MODE must be 'saas' or 'self-managed', not '$CAMUNDA_CLIENT_MODE'" ;;
    esac

    CAMUNDA_CLUSTER_REGION=${CAMUNDA_CLUSTER_REGION:-${CAMUNDA_CLIENT_CLOUD_REGION:-}}
    if [ -z "${CAMUNDA_REST_ADDRESS:-}" ]; then
        [ "$CAMUNDA_CLIENT_MODE" = saas ] ||
            camunda_die "CAMUNDA_REST_ADDRESS is not set for environment '$CAMUNDA_ENV'"
        _camunda_require CAMUNDA_CLUSTER_REGION CAMUNDA_CLUSTER_ID
        CAMUNDA_REST_ADDRESS="https://$CAMUNDA_CLUSTER_REGION.zeebe.camunda.io/$CAMUNDA_CLUSTER_ID"
    fi
    CAMUNDA_REST_ADDRESS=${CAMUNDA_REST_ADDRESS%/}
    case $CAMUNDA_REST_ADDRESS in
        */v2) CAMUNDA_API_URL=$CAMUNDA_REST_ADDRESS ;;
        *) CAMUNDA_API_URL=$CAMUNDA_REST_ADDRESS/v2 ;;
    esac

    # Authentication.
    CAMUNDA_AUTH_STRATEGY=$(printf '%s' "${CAMUNDA_AUTH_STRATEGY:-oauth}" | tr 'A-Z' 'a-z')
    case $CAMUNDA_AUTH_STRATEGY in
        oauth)
            if [ "$CAMUNDA_CLIENT_MODE" = saas ]; then
                CAMUNDA_OAUTH_URL=${CAMUNDA_OAUTH_URL:-$CAMUNDA_SAAS_OAUTH_URL}
                CAMUNDA_TOKEN_AUDIENCE=${CAMUNDA_TOKEN_AUDIENCE:-$CAMUNDA_SAAS_TOKEN_AUDIENCE}
            fi
            _camunda_require CAMUNDA_OAUTH_URL CAMUNDA_CLIENT_ID CAMUNDA_CLIENT_SECRET
            # One cached token per environment and client; changing the
            # client or audience in a profile starts a fresh cache entry.
            _clp_key=$(printf '%s|%s|%s|%s' "$CAMUNDA_OAUTH_URL" "$CAMUNDA_CLIENT_ID" \
                "${CAMUNDA_TOKEN_AUDIENCE:-}" "${CAMUNDA_TOKEN_SCOPE:-}" | cksum | cut -d' ' -f1)
            _camunda_token_file=$_camunda_cache_dir/token-$CAMUNDA_ENV-$_clp_key
            ;;
        basic)
            _camunda_require CAMUNDA_BASIC_AUTH_USERNAME CAMUNDA_BASIC_AUTH_PASSWORD
            ;;
        none) ;;
        *) camunda_die "CAMUNDA_AUTH_STRATEGY must be oauth, basic or none, not '$CAMUNDA_AUTH_STRATEGY'" ;;
    esac
}

# --- OAuth tokens -------------------------------------------------------

# Sets _camunda_token, from the cache when it is still valid.
_camunda_get_token() {
    _cgt_now=$(date +%s)
    if [ -f "$_camunda_token_file" ]; then
        _cgt_exp= _cgt_tok=
        { read -r _cgt_exp && read -r _cgt_tok; } <"$_camunda_token_file" || :
        if [ -n "$_cgt_tok" ] && [ "${_cgt_exp:-0}" -gt "$_cgt_now" ] 2>/dev/null; then
            _camunda_token=$_cgt_tok
            return 0
        fi
    fi
    _camunda_request_token
}

# Requests a token with the client-credentials grant and caches it.
_camunda_request_token() {
    _crt_cfg=$CAMUNDA_TMPDIR/token.cfg
    _crt_body=$CAMUNDA_TMPDIR/token.json
    {
        printf 'url = "%s"\n' "$(_camunda_cfg_escape "$CAMUNDA_OAUTH_URL")"
        printf 'data = "grant_type=client_credentials"\n'
        printf 'data-urlencode = "client_id=%s"\n' "$(_camunda_cfg_escape "$CAMUNDA_CLIENT_ID")"
        printf 'data-urlencode = "client_secret=%s"\n' "$(_camunda_cfg_escape "$CAMUNDA_CLIENT_SECRET")"
        if [ -n "${CAMUNDA_TOKEN_AUDIENCE:-}" ]; then
            printf 'data-urlencode = "audience=%s"\n' "$(_camunda_cfg_escape "$CAMUNDA_TOKEN_AUDIENCE")"
        fi
        if [ -n "${CAMUNDA_TOKEN_SCOPE:-}" ]; then
            printf 'data-urlencode = "scope=%s"\n' "$(_camunda_cfg_escape "$CAMUNDA_TOKEN_SCOPE")"
        fi
    } >"$_crt_cfg"

    _crt_status=$(curl -sS -K "$_crt_cfg" -o "$_crt_body" -w '%{http_code}') ||
        camunda_die "token request to $CAMUNDA_OAUTH_URL failed"
    case $_crt_status in
        2??) ;;
        *)
            if [ -s "$_crt_body" ]; then
                cat "$_crt_body" >&2 && echo >&2
            fi
            case $_crt_status in
                400 | 401 | 403)
                    camunda_warn "the identity provider rejected CAMUNDA_CLIENT_ID/CAMUNDA_CLIENT_SECRET" \
                        "for '$CAMUNDA_ENV'; check both come from the same, current client"
                    ;;
            esac
            camunda_die "token request to $CAMUNDA_OAUTH_URL returned HTTP $_crt_status"
            ;;
    esac

    _camunda_token=$(sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_crt_body")
    [ -n "$_camunda_token" ] || camunda_die "no access_token in response from $CAMUNDA_OAUTH_URL"
    _crt_ttl=$(sed -n 's/.*"expires_in"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9][0-9]*\).*/\1/p' "$_crt_body")

    # Cache until a minute before expiry; a failed write only costs speed.
    _crt_exp=$(($(date +%s) + ${_crt_ttl:-300} - 60))
    if mkdir -p "$_camunda_cache_dir" 2>/dev/null &&
        printf '%s\n%s\n' "$_crt_exp" "$_camunda_token" >"$_camunda_token_file.$$" 2>/dev/null; then
        mv -f "$_camunda_token_file.$$" "$_camunda_token_file"
    else
        rm -f "$_camunda_token_file.$$"
        camunda_warn "could not cache token in $_camunda_cache_dir"
    fi
}

# Forgets the cached token for the current environment.
camunda_clear_token() {
    if [ -n "${_camunda_token_file:-}" ]; then
        rm -f "$_camunda_token_file"
    fi
}

# --- API calls ----------------------------------------------------------

# camunda_api METHOD PATH [CURL-ARGS...]
#
# Calls the Orchestration API, e.g. camunda_api GET /topology. PATH is
# relative to the /v2 base URL. Extra arguments go straight to curl, e.g.
#   camunda_api POST /process-instances/search --data @query.json
# Requests are sent as JSON. Stdin is left free, so '--data @-' works too.
# (curl's --json would also do, but needs curl 7.82 or later.)
#
# The response body goes to stdout (pretty-printed with jq when stdout is a
# terminal). On an HTTP error it goes to stderr and the function returns 1.
camunda_api() {
    [ $# -ge 2 ] || camunda_die "usage: camunda_api METHOD PATH [CURL-ARGS...]"
    _ca_method=$1
    _ca_url=$CAMUNDA_API_URL/${2#/}
    shift 2

    _ca_cfg=$CAMUNDA_TMPDIR/api.cfg
    _ca_body=$CAMUNDA_TMPDIR/api.body
    {
        printf 'url = "%s"\n' "$(_camunda_cfg_escape "$_ca_url")"
        printf 'request = "%s"\n' "$(_camunda_cfg_escape "$_ca_method")"
        printf 'header = "Accept: application/json"\n'
        printf 'header = "Content-Type: application/json"\n'
    } >"$_ca_cfg"
    case $CAMUNDA_AUTH_STRATEGY in
        oauth)
            _camunda_get_token
            printf 'header = "Authorization: Bearer %s"\n' "$(_camunda_cfg_escape "$_camunda_token")" >>"$_ca_cfg"
            ;;
        basic)
            printf 'user = "%s"\n' "$(_camunda_cfg_escape "$CAMUNDA_BASIC_AUTH_USERNAME:$CAMUNDA_BASIC_AUTH_PASSWORD")" >>"$_ca_cfg"
            ;;
    esac

    _ca_status=$(curl -sS -K "$_ca_cfg" -o "$_ca_body" -w '%{http_code}' "$@") ||
        camunda_die "$_ca_method $_ca_url failed"

    case $_ca_status in
        2??)
            if [ -t 1 ] && [ -s "$_ca_body" ] && command -v jq >/dev/null 2>&1; then
                jq . "$_ca_body" 2>/dev/null || cat "$_ca_body"
            else
                cat "$_ca_body"
                # Keep the shell prompt off the end of unterminated JSON.
                if [ -n "$(tail -c 1 "$_ca_body")" ]; then echo; fi
            fi
            return 0
            ;;
        401)
            # Revoked or otherwise rejected: don't keep offering it.
            camunda_clear_token
            ;;
    esac
    if [ -s "$_ca_body" ]; then
        cat "$_ca_body" >&2 && echo >&2
    fi
    camunda_warn "$_ca_method $_ca_url returned HTTP $_ca_status"
    return 1
}

# camunda_require_command NAME...
#
# Fails with a clear message unless each command is installed.
camunda_require_command() {
    for _crc_cmd in "$@"; do
        command -v "$_crc_cmd" >/dev/null 2>&1 ||
            camunda_die "'$_crc_cmd' is required but not installed"
    done
}

# camunda_search PATH [QUERY]
#
# Runs a search endpoint to the end, following the paging cursor, and
# writes every item to stdout, one compact JSON object per line (so
# 'jq -s' gives an array). QUERY is the request body without 'page', e.g.
#   camunda_search /process-definitions/search '{"filter":{"isLatestVersion":true}}'
# CAMUNDA_PAGE_SIZE sets the page size (default 1000; the API allows 10000).
# Needs jq. Redirect the output to a file rather than piping it if you need
# to know whether the search failed.
camunda_search() {
    [ $# -ge 1 ] || camunda_die "usage: camunda_search PATH [QUERY]"
    camunda_require_command jq
    _cs_path=$1
    _cs_query=${2:-'{}'}
    _cs_limit=${CAMUNDA_PAGE_SIZE:-1000}
    case $_cs_limit in
        '' | *[!0-9]* | 0*) camunda_die "CAMUNDA_PAGE_SIZE must be a positive number, not '$_cs_limit'" ;;
    esac
    _cs_req=$CAMUNDA_TMPDIR/search.req
    _cs_page=$CAMUNDA_TMPDIR/search.page
    _cs_after=

    while :; do
        printf '%s' "$_cs_query" |
            jq -c --argjson limit "$_cs_limit" --arg after "$_cs_after" \
                '.page = {limit: $limit} + (if $after == "" then {} else {after: $after} end)' \
                >"$_cs_req" 2>/dev/null ||
            camunda_die "search query is not a JSON object: $_cs_query"

        camunda_api POST "$_cs_path" --data @"$_cs_req" >"$_cs_page" || return 1
        jq -c '.items[]' "$_cs_page" || camunda_die "unexpected response from $_cs_path"

        _cs_count=$(jq '.items | length' "$_cs_page")
        _cs_prev=$_cs_after
        _cs_after=$(jq -r '.page.endCursor // empty' "$_cs_page")
        # A short page, no cursor, or a cursor that doesn't move: done.
        if [ "$_cs_count" -lt "$_cs_limit" ] || [ -z "$_cs_after" ] ||
            [ "$_cs_after" = "$_cs_prev" ]; then
            return 0
        fi
    done
}

# --- version selectors --------------------------------------------------

# camunda_select_versions [--check] SELECTOR...
#
# Reads a process's deployed version numbers on stdin, one per line, and
# prints the ones the selectors pick, ascending. Selectors are words and
# numbers, separated by spaces or commas; any mix may be combined:
#
#   670 671                     exact versions
#   27-100, 27 to 100           an inclusive range
#   first-600, 600-last         ranges from the oldest / to the newest
#                               deployed version (600- also works)
#   <50  <=50  >50  >=50        comparisons (quote them in the shell)
#   older than 50, before 50    same as <50  (also: below)
#   newer than 50, after 50     same as >50  (also: above)
#   oldest 10                   the 10 oldest deployed versions
#   newest 5, latest 5          the 5 newest (a bare 'latest' means 1)
#   all                         every deployed version
#   except ..., but ...         remove what follows, e.g. 'all but newest 5'
#                               (with nothing before it, 'all' is implied)
#
# 'oldest' and 'newest' count deployed versions, which may have gaps.
# Exit status: 0; 1 if an exact version named isn't deployed (the rest are
# still printed); 2 if the selectors are invalid (with a message). With
# --check only the syntax is checked: run it with empty input before any
# API calls to report mistakes early.
camunda_select_versions() {
    _csv_check=
    if [ "${1:-}" = --check ]; then
        _csv_check=1
        shift
    fi
    sort -n -u | awk -v prog="${0##*/}" -v sel="$*" -v check="$_csv_check" '
        function fail(msg) {
            printf "%s: error: %s\n", prog, msg >"/dev/stderr"
            failed = 1
            exit 2
        }
        function isnum(s) { return s ~ /^[0-9]+$/ }
        function isend(s) { return isnum(s) || s == "first" || s == "last" }
        function num(i, what) {
            if (i > nt || !isnum(tok[i])) fail("\"" what "\" needs a version number")
            return tok[i] + 0
        }
        function mark(x) {
            if (excluding) { out[x] = 1 } else { in_[x] = 1 }
        }
        function range(lo, hi,   j) {
            for (j = 1; j <= nv; j++) if (v[j] >= lo && v[j] <= hi) mark(v[j])
        }
        function term() { if (excluding) nexcl++; else nincl++ }

        /^[0-9]+$/ { v[++nv] = $1 + 0; deployed[$1 + 0] = 1 }

        END {
            if (failed) exit 2
            INF = 1e18
            s = tolower(sel)
            gsub(/,/, " ", s)
            gsub(/<=/, " LE ", s); gsub(/>=/, " GE ", s)
            gsub(/</, " LT ", s); gsub(/>/, " GT ", s)
            nt = split(s, tok, " ")

            for (i = 1; i <= nt; i++) {
                t = tok[i]
                if (t == "except" || t == "but") {
                    if (excluding) fail("\"" t "\" used twice")
                    excluding = 1
                    continue
                }
                term()
                if (isend(t) && (tok[i + 1] == "-" || tok[i + 1] == "to") && isend(tok[i + 2])) {
                    t = t "-" tok[i + 2]
                    i += 2
                }
                if (isnum(t)) {
                    range(t + 0, t + 0)
                    if (!excluding && !check && !deployed[t + 0]) missing = missing " " t
                } else if (t ~ /^([0-9]+|first)-([0-9]+|last)$/) {
                    split(t, r, "-")
                    lo = r[1] == "first" ? -1 : r[1] + 0
                    hi = r[2] == "last" ? INF : r[2] + 0
                    if (lo > hi) fail("range \"" t "\" is backwards")
                    range(lo, hi)
                } else if (t ~ /^[0-9]+-$/) {
                    range(substr(t, 1, length(t) - 1) + 0, INF)
                } else if (t == "first" || t == "last") {
                    fail("\"" t "\" is the end of a range, e.g. first-600 or 600-last" \
                        " (for a number of versions, use oldest N or newest N)")
                } else if (t == "LT") { range(-1, num(++i, "<") - 1)
                } else if (t == "LE") { range(-1, num(++i, "<="))
                } else if (t == "GT") { range(num(++i, ">") + 1, INF)
                } else if (t == "GE") { range(num(++i, ">="), INF)
                } else if (t == "older" || t == "before" || t == "below") {
                    if (tok[i + 1] == "than") i++
                    range(-1, num(++i, t) - 1)
                } else if (t == "newer" || t == "after" || t == "above") {
                    if (tok[i + 1] == "than") i++
                    range(num(++i, t) + 1, INF)
                } else if (t == "oldest") {
                    n = num(++i, t)
                    for (j = 1; j <= nv && j <= n; j++) mark(v[j])
                } else if (t == "newest" || t == "latest") {
                    n = 1
                    if (isnum(tok[i + 1])) n = tok[++i] + 0
                    for (j = nv; j >= 1 && j > nv - n; j--) mark(v[j])
                } else if (t == "all") {
                    range(-1, INF)
                } else {
                    fail("unknown version selector \"" tok[i] "\"")
                }
            }
            if (!nincl && !nexcl) fail("no versions selected")
            if (excluding && !nexcl) fail("nothing after \"except\"/\"but\"")

            for (j = 1; j <= nv; j++)
                if ((!nincl || in_[v[j]]) && !out[v[j]]) print v[j]
            if (missing != "") {
                printf "%s: warning: not deployed:%s\n", prog, missing >"/dev/stderr"
                exit 1
            }
        }'
}

# camunda_format_ranges
#
# Reads ascending numbers on stdin and prints them compactly on one line,
# e.g. "337-346, 400, 402-410".
camunda_format_ranges() {
    awk '
        function flush() {
            if (start == "") return
            out = out (out == "" ? "" : ", ") (start == prev ? start : start "-" prev)
        }
        NF {
            if (start != "" && $1 == prev + 1) { prev = $1; next }
            flush()
            start = prev = $1
        }
        END { flush(); print out }'
}

# --- process versions and their instances -------------------------------
#
# The building blocks of commands that act on process versions, such as
# c8-cancel-process-instances:
#
#   camunda_check_version_args "$@"      # before camunda_load_profile
#   camunda_load_profile
#   camunda_resolve_versions "$@" || status=$?
#   camunda_find_instances '{"state": "ACTIVE"}' "$CAMUNDA_TMPDIR/active"
#   camunda_count_instances "$CAMUNDA_TMPDIR/active" >"$CAMUNDA_TMPDIR/counts"
#   camunda_run_batches /process-instances/cancellation '{}' <"$CAMUNDA_TMPDIR/counts"
#
# The versions come from the command line (PROCESS_ID VERSIONS..., with the
# selectors of camunda_select_versions) or from stdin ("processDefinitionId
# version" lines, as c8-list-process-versions prints).

# camunda_check_version_args "$@"
#
# Reports usage mistakes in the operands before anything else happens.
camunda_check_version_args() {
    if [ $# -eq 1 ]; then
        camunda_usage_error "say which versions of '$1', e.g. 670, 27-100, 'oldest 10' or 'all but newest 5'"
    fi
    if [ $# -eq 0 ] && [ -t 0 ]; then
        camunda_usage_error "no process versions: name them, or pipe them in (e.g. from c8-list-process-versions)"
    fi
    if [ $# -gt 1 ]; then
        shift
        if ! camunda_select_versions --check "$@" </dev/null; then
            printf "Try '%s --help' for more information.\n" "${0##*/}" >&2
            exit 2
        fi
    fi
}

# camunda_resolve_versions "$@"
#
# Works out which deployed versions are meant and writes them to the file
# named by CAMUNDA_TARGETS, as "processDefinitionId version
# processDefinitionKey" lines in input order. The key pins down exactly one
# version. Returns 1 if some requested versions aren't deployed (after
# warning about them); exits on malformed input.
camunda_resolve_versions() {
    camunda_require_command jq
    CAMUNDA_TARGETS=$CAMUNDA_TMPDIR/targets
    _crv_status=0
    _crv_id=
    _crv_req=$CAMUNDA_TMPDIR/requested
    _crv_ids=$CAMUNDA_TMPDIR/ids
    _crv_defs=$CAMUNDA_TMPDIR/definitions
    : >"$CAMUNDA_TARGETS"

    if [ $# -gt 0 ]; then
        _crv_id=$1
        shift
        printf '%s\n' "$_crv_id" >"$_crv_ids"
    else
        # Piped in: "id version" lines, first occurrence only.
        awk 'NF == 1 { print "BAD " NR ": " $0; next } NF { print $(NF - 1), $NF }' |
            awk '!seen[$0]++' >"$_crv_req"
        if grep '^BAD ' "$_crv_req" >"$CAMUNDA_TMPDIR/bad"; then
            sed 's/^BAD \([0-9]*\): /line \1: expected "PROCESS_ID VERSION", got: /' "$CAMUNDA_TMPDIR/bad" |
                while IFS= read -r _crv_line; do camunda_warn "$_crv_line"; done
            camunda_die "no changes made"
        fi
        if awk '$2 !~ /^[0-9]+$/ { bad = 1; print "version must be a number: " $0 } END { exit !bad }' \
            "$_crv_req" >"$CAMUNDA_TMPDIR/bad"; then
            while IFS= read -r _crv_line; do camunda_warn "$_crv_line"; done <"$CAMUNDA_TMPDIR/bad"
            camunda_die "no changes made"
        fi
        [ -s "$_crv_req" ] || return 0
        awk '!seen[$1]++ { print $1 }' "$_crv_req" >"$_crv_ids"
    fi

    # The deployed versions and their keys, one search per 100 process ids.
    : >"$_crv_defs"
    split -l 100 "$_crv_ids" "$_crv_ids."
    for _crv_batch in "$_crv_ids".*; do
        [ -f "$_crv_batch" ] || continue
        _crv_query=$(jq -R -s -c '{filter: {processDefinitionId: {"$in": split("\n") | map(select(. != ""))}}}' \
            "$_crv_batch")
        camunda_search /process-definitions/search "$_crv_query" >>"$_crv_defs" || exit 1
    done
    rm -f "$_crv_ids".*

    # Named on the command line: apply the selectors to what's deployed.
    if [ -n "$_crv_id" ]; then
        _crv_deployed=$CAMUNDA_TMPDIR/deployed
        jq -r --arg id "$_crv_id" 'select(.processDefinitionId == $id) | .version' "$_crv_defs" |
            sort -n >"$_crv_deployed"
        if [ ! -s "$_crv_deployed" ]; then
            camunda_warn "no deployed versions of '$_crv_id' in '$CAMUNDA_ENV'"
            return 1
        fi
        camunda_select_versions "$@" <"$_crv_deployed" >"$CAMUNDA_TMPDIR/selected" || _crv_status=$?
        [ "$_crv_status" -le 1 ] || exit "$_crv_status"
        if [ ! -s "$CAMUNDA_TMPDIR/selected" ]; then
            camunda_warn "no deployed versions of '$_crv_id' match '$*'" \
                "(deployed: $(camunda_format_ranges <"$_crv_deployed"))"
            return 1
        fi
        printf '%s: selected %s version(s) of %s: %s\n' "${0##*/}" \
            "$(wc -l <"$CAMUNDA_TMPDIR/selected" | tr -d ' ')" "$_crv_id" \
            "$(camunda_format_ranges <"$CAMUNDA_TMPDIR/selected")" >&2
        awk -v id="$_crv_id" '{ print id, $1 }' "$CAMUNDA_TMPDIR/selected" >"$_crv_req"
    fi

    # "id version key" for each requested version that exists.
    jq -n -r --rawfile requested "$_crv_req" --slurpfile defs "$_crv_defs" '
        ($defs | map({key: "\(.processDefinitionId) \(.version)", value: .processDefinitionKey})
            | from_entries) as $keys
        | $requested | split("\n")[] | select(. != "") | select($keys[.]) | "\(.) \($keys[.])"
    ' >"$CAMUNDA_TARGETS"
    awk -v targets="$CAMUNDA_TARGETS" '
        BEGIN { while ((getline line <targets) > 0) { split(line, f, " "); found[f[1] " " f[2]] = 1 } }
        !found[$0]' "$_crv_req" |
        while IFS= read -r _crv_line; do
            camunda_warn "not deployed in '$CAMUNDA_ENV', skipped: $_crv_line"
        done
    if [ "$(wc -l <"$CAMUNDA_TARGETS")" -lt "$(wc -l <"$_crv_req")" ]; then
        _crv_status=1
    fi
    return "$_crv_status"
}

# camunda_find_instances FILTER OUTFILE
#
# Writes the instances of the target versions (see camunda_resolve_versions)
# that match FILTER, a JSON object of process instance filter fields, one
# per line. Searches by process id, 100 ids at a time, and picks out the
# target versions locally: far fewer requests than filtering on version
# keys, since one process can have hundreds of versions.
camunda_find_instances() {
    _cfi_all=$CAMUNDA_TMPDIR/found.all
    : >"$_cfi_all"
    : >"$2"
    awk '!seen[$1]++ { print $1 }' "$CAMUNDA_TARGETS" | split -l 100 - "$CAMUNDA_TMPDIR/pids."
    for _cfi_batch in "$CAMUNDA_TMPDIR"/pids.*; do
        [ -f "$_cfi_batch" ] || continue
        _cfi_query=$(jq -R -s -c --argjson extra "$1" '
            {filter: ({processDefinitionId: {"$in": split("\n") | map(select(. != ""))}} + $extra)}' \
            "$_cfi_batch")
        camunda_search /process-instances/search "$_cfi_query" >>"$_cfi_all" || exit 1
    done
    rm -f "$CAMUNDA_TMPDIR"/pids.*
    if [ -s "$_cfi_all" ]; then
        jq -c --rawfile targets "$CAMUNDA_TARGETS" '
            ($targets | split("\n") | map(select(. != "") | split(" ")[2] | {key: ., value: true})
                | from_entries) as $wanted
            | select($wanted[.processDefinitionKey])' "$_cfi_all" >"$2"
    fi
    rm -f "$_cfi_all"
}

# camunda_count_instances FILE
#
# For each target version prints "processDefinitionId version key count",
# counting the instances in FILE (from camunda_find_instances).
camunda_count_instances() {
    jq -n -r --rawfile targets "$CAMUNDA_TARGETS" --slurpfile found "$1" '
        ($found | group_by(.processDefinitionKey) | map({key: .[0].processDefinitionKey, value: length})
            | from_entries) as $n
        | $targets | split("\n")[] | select(. != "") | split(" ") as [$id, $v, $k]
        | "\($id) \($v) \($k) \($n[$k] // 0)"'
}

# camunda_list_instances FILE
#
# Prints "processDefinitionId version processInstanceKey" for each instance
# in FILE (from camunda_find_instances), in target order.
camunda_list_instances() {
    jq -n -r --rawfile targets "$CAMUNDA_TARGETS" --slurpfile found "$1" '
        ($found | group_by(.processDefinitionKey)
            | map({key: .[0].processDefinitionKey, value: (map(.processInstanceKey) | sort)})
            | from_entries) as $instances
        | $targets | split("\n")[] | select(. != "") | split(" ") as [$id, $v, $k]
        | ($instances[$k] // [])[] | "\($id) \($v) \(.)"'
}

# camunda_run_batches PATH FILTER
#
# Reads "processDefinitionId version key count" lines (camunda_count_instances)
# on stdin and, for each version with a count above zero, starts a batch
# operation: POST PATH with the filter {processDefinitionKey: key} plus
# FILTER's fields. Prints "processDefinitionId version batchOperationKey"
# for each one started, and sets CAMUNDA_BATCHED to the total count of
# instances they cover. Returns 1 if any failed to start.
camunda_run_batches() {
    CAMUNDA_BATCHED=0
    _crb_status=0
    while read -r _crb_id _crb_v _crb_key _crb_n; do
        [ "$_crb_n" -gt 0 ] || continue
        # The filter must pin a single version: without a key, a batch
        # operation would match every instance in the cluster.
        case $_crb_key in
            '' | *[!0-9]*) camunda_die "refusing to continue: bad processDefinitionKey '$_crb_key' for $_crb_id $_crb_v" ;;
        esac
        jq -n -c --arg key "$_crb_key" --argjson extra "$2" '{filter: ($extra + {processDefinitionKey: $key})}' \
            >"$CAMUNDA_TMPDIR/batch.json"
        if camunda_api POST "$1" --data @"$CAMUNDA_TMPDIR/batch.json" >"$CAMUNDA_TMPDIR/batch.out"; then
            printf '%s %s %s\n' "$_crb_id" "$_crb_v" "$(jq -r '.batchOperationKey' "$CAMUNDA_TMPDIR/batch.out")"
            CAMUNDA_BATCHED=$((CAMUNDA_BATCHED + _crb_n))
        else
            camunda_warn "could not start the batch operation for $_crb_id $_crb_v"
            _crb_status=1
        fi
    done
    return "$_crb_status"
}

# --- safety -------------------------------------------------------------

# Succeeds if the current environment is protected (see CAMUNDA_PROTECTED).
camunda_is_protected() {
    case ${CAMUNDA_PROTECTED:-} in
        true | yes | 1) return 0 ;;
        false | no | 0) return 1 ;;
        '') [ "$CAMUNDA_ENV" = prod ] ;;
        *) camunda_die "CAMUNDA_PROTECTED must be true or false, not '$CAMUNDA_PROTECTED'" ;;
    esac
}

# camunda_confirm "cancel 12 process instances"
#
# Call before any change. In a protected environment, asks the user to type
# the environment name, unless CAMUNDA_ASSUME_YES=1 (set it from a -y/--yes
# option).
# Not tied to HTTP methods: the API also uses POST for read-only searches.
camunda_confirm() {
    camunda_is_protected || return 0
    [ "${CAMUNDA_ASSUME_YES:-}" = 1 ] && return 0
    (exec </dev/tty) 2>/dev/null ||
        camunda_die "refusing to $1 in '$CAMUNDA_ENV' without confirmation (no terminal; use -y/--yes)"
    printf "About to %s in '%s'. Type the environment name to continue: " "$1" "$CAMUNDA_ENV" >/dev/tty
    _cc_answer=
    read -r _cc_answer </dev/tty || :
    [ "$_cc_answer" = "$CAMUNDA_ENV" ] || camunda_die "aborted"
}
