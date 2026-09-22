#!/usr/bin/env bash
# Shared test helpers. tests/test-*.sh source this file.
set -euo pipefail
FAILURES=0
PASSES=0

ok() { PASSES=$((PASSES + 1)); echo "  ok - $1"; }
fail() { FAILURES=$((FAILURES + 1)); echo "  NOT OK - $1" >&2; }

assert_eq() {
    if [[ "$1" == "$2" ]]; then ok "$3"; else fail "$3: expected [$2], got [$1]"; fi
}

assert_file_contains() {
    if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else fail "$3: file $1 missing [$2]"; fi
}

assert_exit_code() {
    local expected="$1"; shift
    local got=0
    local log="$TEST_TMP/assert-exit-code.log"
    "$@" >"$log" 2>&1 || got=$?
    if [[ "$got" == "$expected" ]]; then
        ok "$1 exits with $expected"
    else
        echo "---- output of failing command ($1):" >&2
        head -8 "$log" >&2
        echo "----" >&2
        fail "$1 exits with $expected (got $got)"
    fi
}

finish() {
    echo "-- $PASSES passed, $FAILURES failed"
    [[ "$FAILURES" -eq 0 ]]
}

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/livesync-headless-test.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT
