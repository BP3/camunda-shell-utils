# shellcheck shell=sh disable=SC2034 # fixture= and profiles= are read by tests/lib.sh
# Customer profiles and c8sh profile: acme (dev, prod) and globex (dev).

fixture=basic
profiles=customers

test_nothing_chosen() {
    run c8sh profile
    assert_status 0
    assert_stdout_has 'customer     none'
    assert_stdout_has 'choose       a customer: acme globex'
    run c8sh cluster topology
    assert_status 1
    assert_stderr_has 'no environment selected'
}

test_list() {
    run c8sh profile list
    assert_stdout '  acme/dev
  acme/prod
  globex/dev'
}

test_use_saves_a_default_for_every_command() {
    run c8sh profile use acme dev
    assert_status 0
    assert_stdout 'saved default: acme/dev'
    run c8sh profile prompt
    assert_stdout 'acme/dev'
    run c8sh profile list
    assert_stdout '* acme/dev
  acme/prod
  globex/dev'
    run c8sh cluster topology
    assert_status 0
    run c8sh profile use globex/dev
    assert_stdout 'saved default: globex/dev'
}

test_show_says_where_choices_came_from() {
    run c8sh profile use acme dev
    run c8sh profile
    assert_stdout_has 'customer     acme                     (saved default)'
    assert_stdout_has 'environment  dev                      (saved default)'
    assert_stdout_has 'acme/common.env'
    assert_stdout_has "address      $MOCK_URL"
    assert_stdout_has 'confirm      no (CAMUNDA_PROTECTED is false)'
    run c8sh profile -c acme -e prod
    assert_stdout_has '(--customer)'
    assert_stdout_has "confirm      yes: changes need you to type 'acme/prod'"
}

test_options_and_variables_win_over_the_default() {
    run c8sh profile use acme dev
    run c8sh process list -c globex -e dev
    assert_status 0
    run c8sh process list --customer=globex --environment-name=dev
    assert_status 0
    (CAMUNDA_ENV=prod && export CAMUNDA_ENV && run c8sh profile prompt)
    assert_stdout 'acme/prod'
}

test_saved_environment_never_goes_with_another_customer() {
    run c8sh profile use acme prod
    (CAMUNDA_CUSTOMER=globex && export CAMUNDA_CUSTOMER && run c8sh cluster topology)
    assert_status 1
    assert_stderr_has "no environment selected for customer 'globex'"
    (CAMUNDA_CUSTOMER=globex && export CAMUNDA_CUSTOMER && run c8sh profile prompt)
    assert_stdout 'globex/-'
}

test_use_warns_only_about_real_shell_overrides() {
    run c8sh profile use acme dev
    run c8sh profile use globex/dev
    assert_stderr_lacks 'overrides'
    (CAMUNDA_ENV=prod && export CAMUNDA_ENV && run c8sh profile use acme dev)
    assert_stderr_has 'CAMUNDA_ENV=prod in this shell overrides it here'
}

test_use_without_environment() {
    run c8sh profile use acme
    assert_stdout 'saved default: customer acme, no environment (choose from: dev prod)'
    run c8sh profile
    assert_stdout_has 'choose       an environment: dev prod'
}

test_use_mistakes() {
    run c8sh profile use nosuch
    assert_status 1
    assert_stderr_has "no customer 'nosuch'"
    run c8sh profile use acme nope
    assert_status 1
    assert_stderr_has "no environment 'nope' for acme"
    run c8sh profile use ../etc
    assert_status 1
    assert_stderr_has "invalid customer name"
    [ ! -e "$CAMUNDA_CONFIG_DIR/.current" ] || fail 'a failed use saved a default'
}

test_clear() {
    run c8sh profile use acme dev
    run c8sh profile clear
    assert_stdout 'saved default cleared'
    run c8sh profile prompt
    assert_stdout ''
}

test_messages_and_confirmation_name_the_customer() {
    run c8sh instance cancel -n -c acme -e prod P_A 2
    assert_stderr_has 'dry run in acme/prod'
    run c8sh version delete -c acme -e prod P_Y 1   # no active instances
    assert_status 1
    assert_stderr_has "in 'acme/prod' without confirmation"
    assert_not_sent '/deletion'
}

test_tokens_are_cached_per_customer_and_environment() {
    run c8sh cluster topology -c acme -e dev
    run c8sh cluster topology -c acme -e prod
    run c8sh cluster topology -c globex -e dev
    (cd "$XDG_CACHE_HOME/camunda" && ls) >"$TEST_TMP/tokens"
    grep -q '^token-acme.dev-' "$TEST_TMP/tokens" || fail 'no acme/dev token'
    grep -q '^token-acme.prod-' "$TEST_TMP/tokens" || fail 'no acme/prod token'
    grep -q '^token-globex.dev-' "$TEST_TMP/tokens" || fail 'no globex/dev token'
}

test_flat_profiles_need_a_customer_when_there_are_customers() {
    run c8sh cluster topology -e dev
    assert_status 1
    assert_stderr_has "no profile for 'dev' without a customer"
}

test_saved_default_with_windows_line_endings() {
    printf '# written on Windows\r\ncustomer=acme\r\nenv=dev\r\n' >"$CAMUNDA_CONFIG_DIR/.current"
    run c8sh profile prompt
    assert_stdout 'acme/dev'
    run c8sh cluster topology
    assert_status 0
}

test_confirming_by_typing_customer_and_environment() {
    answer 'prod'
    run c8sh version delete -c acme -e prod P_Y 1
    assert_status 1
    assert_stderr_has "Type 'acme/prod' to continue"
    assert_stderr_has 'aborted'
    assert_not_sent '/deletion'
    answer 'acme/prod'
    run c8sh version delete -c acme -e prod P_Y 1
    assert_status 0
    assert_sent '/v2/resources/903/deletion' 1
}
