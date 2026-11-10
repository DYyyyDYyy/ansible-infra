#!/usr/bin/env bash
# Hammer a URL while a command runs and count the failed requests.
#
#   scripts/zero-downtime.sh http://127.0.0.1:8080/vehicles -- make deploy VERSION=...
#
# Exits non-zero if the command failed or if any request got something other
# than HTTP 200 (including connection errors and timeouts).
set -euo pipefail

url=${1:?usage: $0 <url> -- <command...>}
shift
[[ ${1:-} == -- ]] && shift
(($# > 0)) || { echo "usage: $0 <url> -- <command...>" >&2; exit 2; }

log=$(mktemp)
loop_pid=
cleanup() {
    [[ -n $loop_pid ]] && kill "$loop_pid" 2>/dev/null
    rm -f "$log"
}
trap cleanup EXIT

# Each line: HTTP status (000 = no response), then the time it took.
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

if ((cmd_status != 0)); then
    echo "FAIL: the command exited with $cmd_status" >&2
    exit "$cmd_status"
fi
((failed == 0)) || { echo "FAIL: requests failed during the command" >&2; exit 1; }
echo "OK: no failed requests"
