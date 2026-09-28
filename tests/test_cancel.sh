# shellcheck shell=sh
# c8-cancel-process-instances. In the fixture, the active instances are:
#   1 (P_A v2, a root) called 71 (P_C), which called 81 (P_D)
#   91 (P_B v1, a root) called 92 (P_A v2)
#   31 (P_W, a root; its definition key is malformed)
# 'mock' needs no confirmation; 'prod' does.

fixture=basic

cancellations() {
    grep '"/v2/process-instances/cancellation"' "$MOCK_LOG" || :
}

test_dry_run_lists_whole_call_trees() {
    run c8 c8-cancel-process-instances -n -e mock P_A 2
    assert_status 0
    assert_stdout 'P_A 2 1
P_C 1 71
P_D 1 81'
    assert_stderr_has 'would cancel 3 instance(s): 1 root instance(s) of 1 version(s), with 2 instance(s) they called'
    # 92 is P_A v2 too, but its root (91, P_B) isn't being cancelled.
    assert_stderr_has 'P_A 2 also has 1 active instance(s) called from other processes'
    assert_not_sent 'cancellation'
}

test_called_instance_goes_with_its_own_root() {
    run_with 'P_A 2
P_B 1
' c8 c8-cancel-process-instances -n -e mock
    assert_stdout 'P_A 2 1
P_C 1 71
P_D 1 81
P_B 1 91
P_A 2 92'
    assert_stderr_lacks 'called from other processes'
}

test_cancels_one_batch_per_version_by_key() {
    run_with 'P_A 2
P_B 1
' c8 c8-cancel-process-instances -e mock
    assert_status 0
    assert_stdout_has 'P_A 2 batch-'
    assert_stdout_has 'P_B 1 batch-'
    assert_sent '"body": {"filter": {"processDefinitionKey": "102"}}' 1
    assert_sent '"body": {"filter": {"processDefinitionKey": "201"}}' 1
    [ "$(cancellations | wc -l)" -eq 2 ] || fail 'expected exactly 2 cancellations'
    assert_stderr_has 'started cancelling 2 root instance(s)'
}

test_nothing_active() {
    run c8 c8-cancel-process-instances -e mock P_A 1
    assert_status 0
    assert_stderr_has 'no active instances to cancel'
    assert_not_sent 'cancellation'
}

test_protected_environment_needs_confirmation() {
    run c8 c8-cancel-process-instances -e prod P_A 2
    assert_status 1
    assert_stderr_has "refusing to cancel 3 instance(s)"
    assert_stderr_has "in 'prod' without confirmation"
    assert_not_sent 'cancellation'
    answer 'mock'
    run c8 c8-cancel-process-instances -e prod P_A 2
    assert_status 1
    assert_stderr_has 'aborted'
    assert_not_sent 'cancellation'
    answer 'prod'
    run c8 c8-cancel-process-instances -e prod P_A 2
    assert_status 0
    assert_sent 'cancellation' 1
    run c8 c8-cancel-process-instances -e prod -y P_B 1
    assert_status 0
    assert_sent 'cancellation' 2
}

test_version_states() {
    # Deleted: skipped. Draining: still cancellable (it has none here).
    run_with 'P_A 3
P_B 2
' c8 c8-cancel-process-instances -n -e mock
    assert_status 1
    assert_stderr_has 'already deleted, skipped: P_A 3'
    assert_stderr_lacks 'P_B 2'
    run c8 c8-cancel-process-instances -n -e mock P_A all
    assert_stderr_has 'not considered: 3 (deleted)'
}

test_versions_not_deployed() {
    run c8 c8-cancel-process-instances -n -e mock P_A 2 9
    assert_status 1
    assert_stderr_has 'not deployed: P_A 9'
    assert_stdout_has 'P_A 2 1'
    run c8 c8-cancel-process-instances -n -e mock Nope all
    assert_status 1
    assert_stderr_has "no deployed versions of 'Nope'"
    run c8 c8-cancel-process-instances -n -e mock P_A 27-30
    assert_status 1
    assert_stderr_has "no deployed versions of 'P_A' match '27-30' (deployed: 1-2)"
}

test_input_mistakes_change_nothing() {
    run_with 'P_A
' c8 c8-cancel-process-instances -e mock
    assert_status 1
    assert_stderr_has 'expected "PROCESS_ID VERSION"'
    run_with 'P_A two
' c8 c8-cancel-process-instances -e mock
    assert_status 1
    assert_stderr_has 'version must be a number'
    run c8 c8-cancel-process-instances -e mock P_A
    assert_status 2
    run c8 c8-cancel-process-instances -e mock P_A oldest ten
    assert_status 2
    run c8 c8-cancel-process-instances -e mock P_A 2 --dry-run
    assert_status 2
    assert_stderr_has 'unknown version selector "--dry-run"'
    assert_not_sent 'cancellation'
}

test_malformed_key_stops_everything() {
    # P_A 2 comes first and is fine, but nothing at all may be sent.
    run_with 'P_A 2
P_W 1
' c8 c8-cancel-process-instances -e mock
    assert_status 1
    assert_stderr_has "bad processDefinitionKey '88/../x'"
    assert_not_sent 'cancellation'
}

test_every_request_names_one_version() {
    run c8 c8-cancel-process-instances -e mock P_A all
    run c8 c8-cancel-process-instances -e mock P_B all
    cancellations | grep -v '"filter": {"processDefinitionKey": "[0-9]*"}' >"$TEST_TMP/unkeyed" || :
    [ ! -s "$TEST_TMP/unkeyed" ] || { fail 'a cancellation without exactly one key:'; show requests "$TEST_TMP/unkeyed"; }
}
