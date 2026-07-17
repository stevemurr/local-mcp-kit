#!/usr/bin/env bash
# Runs one test target serially with a hard wall-clock bound so a wedged
# runner process fails its CI step instead of consuming the whole job.
set -uo pipefail

target="${1:?usage: ci-test-target.sh <test-target> [timeout-seconds]}"
timeout_seconds="${2:-420}"

swift test --no-parallel --filter "$target" &
test_pid=$!

(
    sleep "$timeout_seconds"
    echo "::error::$target exceeded ${timeout_seconds}s and was killed"
    kill -9 "$test_pid" 2>/dev/null
) &
watchdog_pid=$!

wait "$test_pid"
status=$?
kill "$watchdog_pid" 2>/dev/null || true
exit "$status"
