# shellcheck shell=sh disable=SC2034 # fixture= is read by tests/lib.sh
# c8sh itself: dispatching, help, options before the noun, and the old
# command names.

fixture=basic

test_overview_lists_every_command() {
    run c8sh --help
    assert_status 0
    for command in 'cluster topology' 'instance cancel' 'instance delete' 'process list' \
        'profile show' 'profile list' 'profile use' 'profile clear' 'profile prompt' \
        'version delete' 'version list'; do
        assert_stdout_has "  $command "
    done
    run c8sh
    assert_status 2
    run c8sh help
    assert_status 0
    assert_stdout_has 'Usage: c8sh'
}

test_noun_help() {
    run c8sh instance --help
    assert_status 0
    assert_stdout_has 'Usage: c8sh instance VERB'
    assert_stdout_has '  cancel '
    assert_stdout_has '  delete '
    run c8sh instance
    assert_status 2
    assert_stderr_has 'Usage: c8sh instance VERB'
}

test_command_help_three_ways() {
    run c8sh instance cancel --help
    assert_stdout_has 'Usage: c8sh instance cancel'
    cp "$TEST_TMP/stdout" "$TEST_TMP/first"
    run c8sh help instance cancel
    cmp -s "$TEST_TMP/first" "$TEST_TMP/stdout" || fail "'help instance cancel' differs"
    run c8sh -h
    assert_status 0
}

test_unknown_commands() {
    for bad in bogus 'instance nope' '../x y' 'instance ../../bin/c8sh' '-x'; do
        # shellcheck disable=SC2086
        run c8sh $bad
        assert_status 2
    done
    run c8sh instance nope
    assert_stderr_has "unknown command 'instance nope'"
    run c8sh -x
    assert_stderr_has "unknown option '-x'"
}

test_messages_name_the_command() {
    run c8sh instance cancel -e mock P_A oldest ten
    assert_status 2
    assert_stderr_has 'c8sh instance cancel: error: "oldest" needs a version number'
    assert_stderr_has "Try 'c8sh instance cancel --help'"
}

test_options_before_the_noun() {
    run c8sh -e mock cluster topology
    assert_status 0
    run c8sh --environment-name=mock process list
    assert_status 0
    assert_stdout_has '"Alpha" P_A'
    run c8sh -emock version list P_A
    assert_stdout 'P_A 1
P_A 2'
    # After the verb wins over before the noun.
    run c8sh -e nosuch process list -e mock
    assert_status 0
    run c8sh -e
    assert_status 2
}

test_options_before_the_noun_with_customers() {
    profiles=customers
    setup_test
    run c8sh -c acme -e prod profile
    assert_stdout_has 'customer     acme                     (--customer)'
    assert_stdout_has 'environment  prod                     (--environment-name)'
    run c8sh -c globex -e dev cluster topology
    assert_status 0
    profiles=
}

test_linked_as_c8() {
    ln -s "$ROOT/bin/c8sh" "$TEST_TMP/c8"
    run $TEST_SHELL "$TEST_TMP/c8" --help
    assert_stdout_has 'Usage: c8 '
    run $TEST_SHELL "$TEST_TMP/c8" -e mock process list
    assert_status 0
    run $TEST_SHELL "$TEST_TMP/c8" instance cancel -e mock P_A oldest ten
    assert_stderr_has 'c8 instance cancel: error:'
    rm -f "$TEST_TMP/c8"
}

test_old_names_still_work() {
    for pair in 'c8-topology:cluster topology' 'c8-list-processes:process list' \
        'c8-list-process-versions:version list' 'c8-cancel-process-instances:instance cancel' \
        'c8-delete-process-instances:instance delete' 'c8-delete-process-versions:version delete'; do
        old=${pair%%:*}
        new=${pair#*:}
        run c8 "$old" --help
        assert_status 0
        assert_stdout_has "Usage: c8sh $new"
        assert_stderr_has "$old: renamed to 'c8sh $new'"
    done
    run c8 c8-list-process-versions -e mock P_A
    assert_stdout 'P_A 1
P_A 2'
    run c8 c8-cancel-process-instances -n -e mock P_A 2
    assert_stdout_has 'P_A 2 1'
}

test_old_profile_name() {
    run c8 c8-profile list
    assert_stderr_has "c8-profile: renamed to 'c8sh profile'"
    # Quiet at the prompt, where it runs every time.
    run c8 c8-profile prompt
    assert_status 0
    assert_stderr_lacks 'renamed'
}
