#!/usr/bin/env bash
# Hammer a URL while a command runs and count the failed requests.
#
#   scripts/zero-downtime.sh [--expect-failure] <url> -- <command...>
#
# Fails if any request got something other than HTTP 200 (connection errors
# and timeouts count as failures). Also fails if the command fails, or, with
# --expect-failure, if the command succeeds (used by the rollback test).
set -euo pipefail

usage() { echo "usage: $0 [--expect-failure] <url> -- <command...>" >&2; exit 2; }

expect_failure=false
if [[ ${1:-} == --expect-failure ]]; then
    expect_failure=true
    shift
fi
url=${1:-}
[[ -n $url ]] || usage
shift
[[ ${1:-} == -- ]] && shift
(($# > 0)) || usage

log=$(mktemp)
loop_pid=
# shellcheck disable=SC2329  # called by the EXIT trap below
cleanup() {
    [[ -n $loop_pid ]] && kill "$loop_pid" 2>/dev/null
    rm -f "$log"
}
trap cleanup EXIT

# One line per request: HTTP status (000 = no response) and duration.
(
    while :; do
        curl -s -o /dev/null --max-time 5 -w '%{http_code} %{time_total}\n' "$url" >>"$log" || true
        sleep 0.02
    done
) &
loop_pid=$!

sleep 1
cmd_status=0
"$@" || cmd_status=$?
sleep 1

kill "$loop_pid" 2>/dev/null || true
wait "$loop_pid" 2>/dev/null || true
loop_pid=

total=$(wc -l <"$log")
failed=$(awk '$1 != 200' "$log" | wc -l)
slowest=$(sort -k2 -n "$log" | tail -1 | awk '{print $2}')

echo
echo "requests: $total   failed: $failed   slowest: ${slowest}s"
if ((failed > 0)); then
    echo "non-200 responses:"
    awk '$1 != 200 {print "  " $1}' "$log" | sort | uniq -c
fi

status=0
if $expect_failure; then
    if ((cmd_status == 0)); then
        echo "FAIL: the command was expected to fail but succeeded" >&2
        status=1
    else
        echo "the command failed as expected (exit $cmd_status)"
    fi
elif ((cmd_status != 0)); then
    echo "FAIL: the command exited with $cmd_status" >&2
    status=1
fi
if ((failed > 0)); then
    echo "FAIL: requests failed during the command" >&2
    status=1
fi
((status == 0)) && echo "OK: no failed requests"
exit "$status"
