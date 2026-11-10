#!/usr/bin/env bash
# Prove that a failed deploy rolls back and leaves the service up.
#
#   scripts/rollback-test.sh <lb-url> <good-version> <bad-version> <ansible-playbook args...>
#
# 1. deploy <good-version> everywhere;
# 2. deploy <bad-version> with a smoke test that cannot pass;
# 3. expect: the deploy fails, the first app host is back on <good-version>
#    and in the load balancer, the second host was never touched, and the
#    site kept answering throughout.
set -euo pipefail

lb_url=$1 good=$2 bad=$3
shift 3

current_release() {
    local host=$1
    shift
    ansible "$host" "$@" -m ansible.builtin.command -a 'readlink /opt/transport-api/current' -o 2>/dev/null |
        sed -n 's/.*(stdout) //p' | xargs basename
}

echo "==> 1/3 deploy the good version $good"
ansible-playbook "$@" playbooks/deploy.yml -e "app_version=$good"

echo "==> 2/3 deploy $bad with a failing smoke test (this deploy must fail)"
if scripts/zero-downtime.sh "$lb_url/vehicles" -- \
    ansible-playbook "$@" playbooks/deploy.yml -e "app_version=$bad" -e app_smoke_test_path=/no-such-page; then
    echo "FAIL: the broken deploy succeeded" >&2
    exit 1
fi

echo "==> 3/3 check the state after the failed deploy"
inv=("$@")
for host in app1 app2; do
    release=$(current_release "$host" "${inv[@]}")
    echo "$host is on $release"
    [[ $release == "$good" ]] || { echo "FAIL: $host should be on $good" >&2; exit 1; }
done

upstream=$(ansible lb "${inv[@]}" -b -m ansible.builtin.command -a 'cat /etc/nginx/conf.d/upstream.conf' 2>/dev/null)
if grep -q ' down;' <<<"$upstream"; then
    echo "FAIL: a host is still drained in nginx:" >&2
    echo "$upstream" >&2
    exit 1
fi
curl -fsS "$lb_url/health" >/dev/null
echo "OK: rolled back to $good, both hosts in the load balancer, site up"
