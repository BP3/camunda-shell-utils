# shellcheck shell=sh disable=SC2034 # fixture= and profiles= are read by tests/lib.sh
# c8-delete-process-instances. In the fixture, the finished instances are:
#   11 (P_A v1, a root) called 41 (P_C), which called 51 (P_D)
#   12 (P_A v2, a root)
#   13 (P_A v2) called by 99, which is gone; 13 called 61 (P_C)
#   15 (P_A v2) called by 1, which is still active
#   14 (P_F v1, a root)
# 'mock' needs no confirmation; 'prod' does.

fixture=basic

deletions() {
    grep '"/v2/process-instances/deletion"' "$MOCK_LOG" || :
}

test_whole_call_trees_by_default() {
    run c8 c8-delete-process-instances -n -e mock P_A all
    assert_status 0
    # Each root, then what it called; 13's parent is gone, so it's a root;
    # 15's parent is still there, so it stays.
    assert_stdout 'P_A 1 11
P_C 1 41
P_D 1 51
P_A 2 12
P_A 2 13
P_C 1 61'
    assert_stderr_has 'would delete 6 instance(s): 3 root instance(s) of 2 version(s) (1 of them called instances whose parent is already gone), with 3 instance(s) they called'
    assert_stderr_has 'skipping 1 called instance(s) of the chosen versions: their parent still exists'
    assert_not_sent 'deletion'
}

test_called_instances_never_go_without_their_parent() {
    # P_C's instances were all called by instances that stay.
    run c8 c8-delete-process-instances -n -e mock P_C all
    assert_status 0
    assert_stdout ''
    assert_stderr_has 'skipping 2 called instance(s)'
}

test_ignore_dependencies() {
    run c8 c8-delete-process-instances -n -e mock --ignore-dependencies P_A all
    assert_status 0
    assert_stdout 'P_A 1 11
P_A 2 12
P_A 2 13
P_A 2 15'
    # 15's parent stays; 41, 51 and 61 are left behind.
    assert_stderr_has '1 of these were called by an instance that stays, and 3 instance(s) they called'
    assert_stderr_has 'ignoring call dependencies'
}

test_deletes_exact_instances_with_a_state_filter() {
    run c8 c8-delete-process-instances -e mock P_A all
    assert_status 0
    assert_stdout_has 'P_A 1 batch-'
    assert_stdout_has 'P_A 2 batch-'
    assert_sent '"filter": {"state": {"$in": \["COMPLETED", "TERMINATED"\]}, "processInstanceKey": {"$in": \["11", "41", "51"\]}}' 1
    assert_sent '"filter": {"state": {"$in": \["COMPLETED", "TERMINATED"\]}, "processInstanceKey": {"$in": \["12", "13", "61"\]}}' 1
    [ "$(deletions | wc -l)" -eq 2 ] || fail 'expected exactly 2 deletions'
    deletions | grep -v '"state": {"$in": \["COMPLETED", "TERMINATED"\]}' >"$TEST_TMP/stateless" || :
    [ ! -s "$TEST_TMP/stateless" ] || fail 'a deletion without the finished-only state filter'
    assert_stderr_has 'started deleting 6 instance(s)'
}

test_active_instances_are_never_deleted() {
    run_with 'P_A 2
P_B 1
' c8 c8-delete-process-instances -n -e mock --ignore-dependencies
    assert_status 0
    assert_stdout_has 'P_A 2 12'
    for key in 1 71 81 91 92; do
        grep -q " $key\$" "$TEST_TMP/stdout" && fail "active instance $key would be deleted"
    done
    :
}

test_deleted_versions_history_can_still_go() {
    # P_A 3 is deleted; its history (none here) is still in scope.
    run c8 c8-delete-process-instances -n -e mock P_A 3
    assert_status 0
    assert_stderr_lacks 'already deleted'
}

test_protected_environment_needs_confirmation() {
    run c8 c8-delete-process-instances -e prod P_A all
    assert_status 1
    assert_stderr_has "in 'prod' without confirmation"
    assert_not_sent 'deletion'
    answer 'prod'
    run c8 c8-delete-process-instances -e prod P_A all
    assert_status 0
    assert_sent 'deletion' 2
}

test_nothing_to_delete() {
    run c8 c8-delete-process-instances -e mock P_Y 1
    assert_status 0
    assert_stderr_has 'no finished instances to delete'
    assert_not_sent 'deletion'
}
