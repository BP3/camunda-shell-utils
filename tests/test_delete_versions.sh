# shellcheck shell=sh disable=SC2034 # fixture= and profiles= are read by tests/lib.sh
# c8-delete-process-versions. In the fixture: P_A has versions 1, 2 (with
# active instances) and 3 (deleted); P_B has 1 (active instances) and 2
# (draining); P_Y has 1, and 2 (deleted); P_F 1 is refused (403); P_X 1 has
# a malformed key. 'mock' needs no confirmation; 'prod' does.

fixture=basic

resource_deletions() {
    grep '"/v2/resources/' "$MOCK_LOG" || :
}

test_versions_with_active_instances_are_skipped() {
    run c8 c8-delete-process-versions -n -e mock P_A all
    assert_status 1
    assert_stdout 'P_A 1'
    assert_stderr_has 'not considered: 3 (deleted)'
    assert_stderr_has 'skipping P_A 2: it has 2 active instance(s); cancel them first (c8-cancel-process-instances P_A 2)'
    assert_stderr_lacks 'latest version'
    assert_not_sent '/v2/resources/'
}

test_allow_active() {
    run c8 c8-delete-process-versions -n -e mock --allow-active P_A 2
    assert_status 0
    assert_stdout 'P_A 2'
    assert_stderr_has '1 version(s) with 2 active instance(s) will drain'
    assert_stderr_has 'the latest version of P_A (2) is being deleted: new instances will start on version 1'
}

test_every_version_warning() {
    run c8 c8-delete-process-versions -n -e mock P_Y all
    assert_status 0
    assert_stdout 'P_Y 1'
    assert_stderr_has 'every deployed version of P_Y is being deleted: the process will no longer be deployed'
}

test_deletes_by_key() {
    run c8 c8-delete-process-versions -e mock P_A 1
    assert_status 0
    assert_stdout 'P_A 1'
    assert_sent '"path": "/v2/resources/101/deletion", "body": {}' 1
    [ "$(resource_deletions | wc -l)" -eq 1 ] || fail 'expected exactly 1 deletion'
    assert_stderr_has 'deleted 1 of 1 process version(s)'
}

test_already_deleted_or_draining() {
    run_with 'P_A 3
P_B 2
P_A 1
' c8 c8-delete-process-versions -n -e mock
    assert_status 1
    assert_stdout 'P_A 1'
    assert_stderr_has 'already deleted, skipped: P_A 3'
    assert_stderr_has 'already being deleted (draining), skipped: P_B 2'
    run c8 c8-delete-process-versions -n -e mock P_A 3
    assert_status 1
    assert_stderr_has 'already deleted: P_A 3'
}

test_delete_history_purges_deleted_versions() {
    run c8 c8-delete-process-versions -n -e mock --delete-history P_A 3
    assert_status 0
    assert_stdout 'P_A 3'
    assert_stderr_has '(1 already deleted: only their history goes), with all their history'
    assert_stderr_has 'whether or not they belong to call trees that stay'
    run c8 c8-delete-process-versions -e mock --delete-history P_A 3
    assert_status 0
    assert_sent '"path": "/v2/resources/103/deletion", "body": {"deleteHistory": true}' 1
    assert_stderr_has 'history is being deleted by batch operation history-103'
}

test_deleted_versions_pipe_into_delete_history() {
    run c8 c8-list-process-versions -e mock --deleted P_A
    cp "$TEST_TMP/stdout" "$TEST_TMP/deleted"
    run_with "$(cat "$TEST_TMP/deleted")" c8 c8-delete-process-versions -n -e mock --delete-history
    assert_status 0
    assert_stdout 'P_A 3'
}

test_refused_deletion_is_reported() {
    run_with 'P_F 1
P_Y 1
' c8 c8-delete-process-versions -e mock
    assert_status 1
    assert_stdout 'P_Y 1'
    assert_stderr_has 'returned HTTP 403'
    assert_stderr_has 'could not delete P_F 1'
    assert_stderr_has 'deleted 1 of 2 process version(s)'
}

test_malformed_key_stops_everything() {
    run_with 'P_Y 1
P_X 1
' c8 c8-delete-process-versions -e mock
    assert_status 1
    assert_stderr_has "bad processDefinitionKey '7/../../x' for P_X 1"
    assert_not_sent '/v2/resources/'
    # Checked before asking, too.
    run c8 c8-delete-process-versions -e prod P_X 1
    assert_stderr_has 'bad processDefinitionKey'
    assert_stderr_lacks 'without confirmation'
}

test_protected_environment_needs_confirmation() {
    run c8 c8-delete-process-versions -e prod P_A 1
    assert_status 1
    assert_stderr_has "refusing to delete 1 version(s) of 1 process(es) in 'prod' without confirmation"
    assert_not_sent '/v2/resources/'
    answer 'prod'
    run c8 c8-delete-process-versions -e prod P_A 1
    assert_status 0
    assert_sent '/v2/resources/101/deletion' 1
}
