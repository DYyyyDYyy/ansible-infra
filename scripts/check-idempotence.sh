#!/usr/bin/env bash
# Run a playbook and fail if any task reported a change.
#
#   scripts/check-idempotence.sh -i inventories/docker playbooks/site.yml ...
#
# Run it right after a successful run: a converged system must stay unchanged.
set -euo pipefail

log=$(mktemp)
trap 'rm -f "$log"' EXIT

ANSIBLE_NOCOLOR=1 ansible-playbook "$@" | tee "$log"

if grep -E '^[^ ]+ +: .*changed=[1-9]' "$log"; then
    echo "FAIL: the second run changed something (see the PLAY RECAP above)" >&2
    exit 1
fi
echo "OK: changed=0 on every host"
