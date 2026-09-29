# shellcheck shell=sh disable=SC2034 # fixture= and profiles= are read by tests/lib.sh
# c8sh process list and c8sh version list: output, order, paging,
# piping, and version states.

fixture=basic

test_list_processes() {
    run c8sh process list -e mock
    assert_status 0
    # By name, ignoring case; the name as JSON; P_Y from its newest version
    # still deployed; P_Z (every version deleted) left out.
    assert_stdout '"Alpha" P_A
"Bad key" P_X
"Bad key, active" P_W
"bravo" P_B
"Called \"C\"" P_C
"Called D" P_D
"Forbidden" P_F
"Yankee" P_Y'
}

test_paging_gives_the_same_answer() {
    run c8sh process list -e mock
    cp "$TEST_TMP/stdout" "$TEST_TMP/one-page"
    (CAMUNDA_PAGE_SIZE=2 && export CAMUNDA_PAGE_SIZE && run c8sh process list -e mock)
    cmp -s "$TEST_TMP/one-page" "$TEST_TMP/stdout" || fail 'paged output differs'
    assert_sent '"after"'
}

test_bad_page_size() {
    (CAMUNDA_PAGE_SIZE=abc && export CAMUNDA_PAGE_SIZE && run c8sh process list -e mock)
    assert_status 1
    assert_stderr_has 'CAMUNDA_PAGE_SIZE must be a positive number'
}

test_list_versions() {
    run c8sh version list -e mock P_B P_A
    assert_status 0
    # In the order asked; P_B 2 is draining, so still listed; P_A 3 is deleted.
    assert_stdout 'P_B 1
P_B 2
P_A 1
P_A 2'
}

test_list_deleted_versions() {
    run c8sh version list -e mock --deleted P_A P_Z
    assert_status 0
    assert_stdout 'P_A 3
P_Z 1'
    run c8sh version list -e mock --deleted P_B
    assert_status 1
    assert_stderr_has "no deleted versions of 'P_B'"
}

test_versions_from_a_pipe() {
    run_with '"Alpha" P_A
"bravo" P_B

"Alpha" P_A
' c8sh version list -e mock
    assert_stdout 'P_A 1
P_A 2
P_B 1
P_B 2'
}

test_unknown_process() {
    run c8sh version list -e mock Nope P_A
    assert_status 1
    assert_stdout 'P_A 1
P_A 2'
    assert_stderr_has "no deployed versions of 'Nope'"
}

test_many_ids_are_batched() {
    ids=$(i=0; while [ $i -lt 150 ]; do echo "Fake_$i"; i=$((i + 1)); done; echo P_A)
    run_with "$ids" c8sh version list -e mock
    assert_status 1
    assert_stdout 'P_A 1
P_A 2'
    assert_sent 'process-definitions/search' 2
}

test_topology() {
    run c8sh cluster topology -e mock
    assert_status 0
    assert_stdout_has '"clusterSize": 1'
}
