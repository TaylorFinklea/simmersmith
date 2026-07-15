#!/usr/bin/env bash
set -euo pipefail

source_file="$(dirname "${BASH_SOURCE[0]}")/release-ios.sh"
eval "$(sed -n '/^processing_state_from_response()/,/^}/p' "$source_file")"
eval "$(sed -n '/^processing_state_result()/,/^}/p' "$source_file")"

assert_state() {
    local expected="$1"
    local response="$2"
    local actual
    actual="$(processing_state_from_response "$response")"
    [[ "$actual" == "$expected" ]]
}

assert_state "" '{"data":[]}'
assert_state "VALID" '{"data":[{"attributes":{"processingState":"VALID"}}]}'
assert_state "INVALID" '{"data":[{"attributes":{"processingState":"INVALID"}}]}'
assert_state "FAILED" '{"data":[{"attributes":{"processingState":"FAILED"}}]}'

assert_result() {
    local expected="$1"
    local state="$2"
    local actual
    if processing_state_result "$state" >/dev/null 2>&1; then
        actual=0
    else
        actual=$?
    fi
    [[ "$actual" == "$expected" ]]
}

assert_result 2 ""
assert_result 0 "VALID"
assert_result 1 "INVALID"
assert_result 1 "FAILED"
assert_result 2 "PROCESSING"

echo "release-ios poll regression tests passed"
