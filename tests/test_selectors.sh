# shellcheck shell=sh
# Version selectors (camunda_select_versions): no API needed.
#
# The versions deployed, for most tests: 337-346 and 667-671, like a
# process whose older versions have been deleted.

deployed='337
338
339
340
341
342
343
344
345
346
667
668
669
670
671
'

# select SELECTORS... : run the selectors against $deployed, compactly.
select_ranges() {
    # shellcheck disable=SC2086
    run_with "$deployed" $TEST_SHELL -c \
        '. "$0/lib/camunda.sh"; camunda_select_versions "$@" | camunda_format_ranges' "$ROOT" "$@"
}

test_exact_versions() {
    select_ranges 670 671
    assert_status 0
    assert_stdout '670-671'
}

test_range() {
    select_ranges 340-345
    assert_stdout '340-345'
    select_ranges 340 to 345
    assert_stdout '340-345'
    select_ranges 340 - 345
    assert_stdout '340-345'
}

test_range_ends() {
    select_ranges first-339
    assert_stdout '337-339'
    select_ranges 669-last
    assert_stdout '669-671'
    select_ranges first-last
    assert_stdout '337-346, 667-671'
    select_ranges 669-
    assert_stdout '669-671'
    select_ranges first to 338
    assert_stdout '337-338'
}

test_comparisons() {
    select_ranges '<339'
    assert_stdout '337-338'
    select_ranges '<=339'
    assert_stdout '337-339'
    select_ranges '>669'
    assert_stdout '670-671'
    select_ranges '>=669'
    assert_stdout '669-671'
}

test_words() {
    select_ranges older than 339
    assert_stdout '337-338'
    select_ranges before 339
    assert_stdout '337-338'
    select_ranges newer than 669
    assert_stdout '670-671'
    select_ranges after 669
    assert_stdout '670-671'
}

test_oldest_and_newest_count_deployed_versions() {
    select_ranges oldest 3
    assert_stdout '337-339'
    select_ranges newest 2
    assert_stdout '670-671'
    select_ranges latest
    assert_stdout '671'
    select_ranges latest 3
    assert_stdout '669-671'
    # Gaps: the 12 oldest run across the gap.
    select_ranges oldest 12
    assert_stdout '337-346, 667-668'
}

test_all_and_except() {
    select_ranges all
    assert_stdout '337-346, 667-671'
    select_ranges all but newest 5
    assert_stdout '337-346'
    select_ranges except newest 14
    assert_stdout '337'
    select_ranges older than 670 except 340-345
    assert_stdout '337-339, 346, 667-669'
}

test_combinations_and_case() {
    select_ranges oldest 2, 670
    assert_stdout '337-338, 670'
    select_ranges OLDEST 2
    assert_stdout '337-338'
}

test_nothing_matches() {
    run_with "$deployed" lib camunda_select_versions 27-100
    assert_status 0
    assert_stdout ''
}

test_exact_version_not_deployed() {
    run_with "$deployed" lib camunda_select_versions 670 9999
    assert_status 1
    assert_stdout '670'
    assert_stderr_has 'not deployed: 9999'
}

test_mistakes() {
    for bad in '100-27' 'oldest' 'oldest ten' 'older than' 'banana' 'all but' 'but 1 except 2' \
        'first 10' 'last 5' 'first' '-340' 'last-first'; do
        # shellcheck disable=SC2086
        run_with "$deployed" lib camunda_select_versions $bad
        assert_status 2
        assert_stdout ''
    done
    run_with "$deployed" lib camunda_select_versions
    assert_status 2
    assert_stderr_has 'no versions selected'
    run_with "$deployed" lib camunda_select_versions first 10
    assert_stderr_has '"first" is the end of a range'
}

test_check_mode_needs_no_versions() {
    run lib camunda_select_versions --check oldest 10
    assert_status 0
    run lib camunda_select_versions --check 670 9999
    assert_status 0
    run lib camunda_select_versions --check bogus
    assert_status 2
    assert_stderr_has 'unknown version selector "bogus"'
}

test_format_ranges() {
    run_with '1
2
3
5
8
9
' lib camunda_format_ranges
    assert_stdout '1-3, 5, 8-9'
}
