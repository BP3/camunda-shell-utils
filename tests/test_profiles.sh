# shellcheck shell=sh disable=SC2034 # fixture= and profiles= are read by tests/lib.sh
# Options, profile files and tokens, in the flat layout (no customers).

fixture=basic

# profile NAME CONTENT : write an environment's profile, private.
profile() {
    printf '%s\n' "$2" >"$CAMUNDA_CONFIG_DIR/$1.env"
    chmod 600 "$CAMUNDA_CONFIG_DIR/$1.env"
}

# show_settings ENV : load ENV and print the settings that came out.
show_settings() {
    # shellcheck disable=SC2086
    run $TEST_SHELL -c '. "$0/lib/camunda.sh"; camunda_load_profile "$1"
        printf "%s\n" "mode=$CAMUNDA_CLIENT_MODE" "api=$CAMUNDA_API_URL" "id=$CAMUNDA_CLIENT_ID" \
            "secret=$CAMUNDA_CLIENT_SECRET" "auth=$CAMUNDA_AUTH_STRATEGY" "label=$CAMUNDA_LABEL"' "$ROOT" "$1"
}

test_profile_is_parsed_not_run() {
    profile quirks "# comment
export CAMUNDA_CLIENT_MODE='self-managed'
  CAMUNDA_REST_ADDRESS=$MOCK_URL/   # trailing comment and slash
CAMUNDA_CLIENT_ID=\"mock-client\"
CAMUNDA_CLIENT_SECRET='mock-secret'
ZEEBE_CLIENT_ID=\"\${CAMUNDA_CLIENT_ID}\"
. ./common.env
CAMUNDA_OAUTH_URL='$MOCK_URL/oauth/token'
CAMUNDA_TOKEN_SCOPE=\"\$(touch $TEST_TMP/pwned)\""
    show_settings quirks
    assert_status 0
    assert_stdout "mode=self-managed
api=$MOCK_URL/v2
id=mock-client
secret=mock-secret
auth=oauth
label=quirks"
    assert_stderr_has 'ignoring line that is not KEY=VALUE'
    assert_stderr_has 'is taken literally, not expanded'
    [ ! -e "$TEST_TMP/pwned" ] || fail 'a command in a profile was run'
}

test_exported_variable_overrides_profile_with_a_warning() {
    CAMUNDA_CLIENT_ID=other
    export CAMUNDA_CLIENT_ID
    show_settings mock
    unset CAMUNDA_CLIENT_ID
    assert_stdout_has 'id=other'
    assert_stderr_has 'CAMUNDA_CLIENT_ID from the environment overrides'
}

test_profile_cannot_choose_the_environment() {
    profile sneaky "CAMUNDA_ENV='prod'
CAMUNDA_CUSTOMER='acme'
CAMUNDA_CLIENT_MODE=self-managed
CAMUNDA_REST_ADDRESS=$MOCK_URL
CAMUNDA_AUTH_STRATEGY=none"
    show_settings sneaky
    assert_stdout_has 'label=sneaky'
    assert_stderr_has 'ignoring CAMUNDA_ENV'
    assert_stderr_has 'ignoring CAMUNDA_CUSTOMER'
}

test_readable_profile_warns() {
    chmod 644 "$CAMUNDA_CONFIG_DIR/mock.env"
    show_settings mock
    assert_status 0
    assert_stderr_has 'is readable by other users'
}

test_saas_address_is_derived() {
    profile saas "CAMUNDA_CLUSTER_REGION=fra-1
CAMUNDA_CLUSTER_ID=abc-123
CAMUNDA_CLIENT_ID=x
CAMUNDA_CLIENT_SECRET=y"
    show_settings saas
    assert_stdout_has 'mode=saas'
    assert_stdout_has 'api=https://fra-1.zeebe.camunda.io/abc-123/v2'
}

test_missing_settings_are_reported() {
    profile broken "CAMUNDA_CLIENT_MODE=self-managed"
    show_settings broken
    assert_status 1
    assert_stderr_has "CAMUNDA_REST_ADDRESS is not set for 'broken'"
}

test_no_environment_chosen() {
    run c8 c8-topology
    assert_status 1
    assert_stderr_has 'no environment selected'
    assert_stderr_has 'mock prod'
}

test_unknown_and_invalid_environments() {
    run c8 c8-topology -e nosuch
    assert_status 1
    assert_stderr_has "no profile for 'nosuch'"
    run c8 c8-topology -e ../x
    assert_status 1
    assert_stderr_has "invalid environment name '../x'"
    run c8 c8-topology -e common
    assert_status 1
}

test_option_forms() {
    for form in '-e mock' '-emock' '--environment-name mock' '--environment-name=mock'; do
        # shellcheck disable=SC2086
        run c8 c8-topology $form
        assert_status 0
        assert_stdout_has '"gatewayVersion": "8.9.0"'
    done
    # -e wins over CAMUNDA_ENV. (A subshell, not a prefix assignment: some
    # shells keep a prefix assignment on a function call set afterwards.)
    (CAMUNDA_ENV=nosuch && export CAMUNDA_ENV && run c8 c8-topology -e mock)
    assert_status 0
}

test_option_mistakes() {
    run c8 c8-topology -x
    assert_status 2
    assert_stderr_has "unknown option '-x'"
    run c8 c8-topology -e
    assert_status 2
    run c8 c8-topology --environment-name=
    assert_status 2
    run c8 c8-topology -e mock extra
    assert_status 2
    assert_stderr_has "unexpected argument 'extra'"
    run c8 c8-topology --help
    assert_status 0
    assert_stdout_has 'Usage: c8-topology'
}

test_token_is_cached() {
    run c8 c8-topology -e mock
    run c8 c8-topology -e mock
    assert_status 0
    assert_sent '"/oauth/token"' 1
    assert_sent '"/v2/topology"' 2
    ls "$XDG_CACHE_HOME"/camunda/token-mock-* >/dev/null 2>&1 || fail 'no token cache file'
}

test_rejected_token_is_forgotten() {
    run c8 c8-topology -e mock
    for f in "$XDG_CACHE_HOME"/camunda/token-mock-*; do
        printf '9999999999\nrevoked\n' >"$f"
    done
    run c8 c8-topology -e mock
    assert_status 1
    assert_stderr_has 'returned HTTP 401'
    run c8 c8-topology -e mock
    assert_status 0
}

test_bad_credentials() {
    profile wrong "CAMUNDA_CLIENT_MODE=self-managed
CAMUNDA_REST_ADDRESS=$MOCK_URL
CAMUNDA_OAUTH_URL=$MOCK_URL/oauth/token
CAMUNDA_CLIENT_ID=mock-client
CAMUNDA_CLIENT_SECRET=wrong"
    run c8 c8-topology -e wrong
    assert_status 1
    assert_stderr_has 'rejected CAMUNDA_CLIENT_ID/CAMUNDA_CLIENT_SECRET'
}

test_awkward_secret_gets_through() {
    # Both kinds of quote, so it has to be unquoted in the profile.
    profile odd "CAMUNDA_CLIENT_MODE=self-managed
CAMUNDA_REST_ADDRESS=$MOCK_URL
CAMUNDA_OAUTH_URL=$MOCK_URL/oauth/token
CAMUNDA_CLIENT_ID=odd-client
CAMUNDA_CLIENT_SECRET=s3cr\"et\\+/&=x %'y"
    run c8 c8-topology -e odd
    assert_status 0
    assert_sent '"client_id": "odd-client"' 1
}

test_windows_line_endings_in_profiles() {
    printf "# edited on Windows\r\nexport CAMUNDA_CLIENT_MODE='self-managed'\r\nCAMUNDA_REST_ADDRESS=%s\r\nCAMUNDA_OAUTH_URL=\"%s/oauth/token\"\r\nCAMUNDA_CLIENT_ID=mock-client\r\nCAMUNDA_CLIENT_SECRET='mock-secret'\r\n\r\n" \
        "$MOCK_URL" "$MOCK_URL" >"$CAMUNDA_CONFIG_DIR/crlf.env"
    chmod 600 "$CAMUNDA_CONFIG_DIR/crlf.env"
    show_settings crlf
    assert_status 0
    if od -c "$TEST_TMP/stdout" | grep -q '\\r'; then
        fail 'a carriage return got into a setting'
    fi
    run c8 c8-topology -e crlf
    assert_status 0
}

test_scripts_have_unix_line_endings() {
    for f in "$ROOT"/bin/* "$ROOT"/lib/*.sh; do
        if od -c "$f" | grep -q '\\r'; then
            fail "$f has Windows line endings"
        fi
    done
}
