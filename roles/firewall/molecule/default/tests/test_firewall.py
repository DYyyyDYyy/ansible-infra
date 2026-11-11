"""Checks for the firewall role, based on `nft -j list ruleset`."""

import json

import pytest


@pytest.fixture(scope="module")
def ruleset(host):
    data = json.loads(host.check_output("nft -j list table inet filter"))["nftables"]
    chains = {c["chain"]["name"]: c["chain"] for c in data if "chain" in c}
    rules = [r["rule"] for r in data if "rule" in r]
    return chains, rules


def test_other_tables_survive(host):
    # prepare.yml created it before the role ran twice (converge, idempotence).
    # `flush ruleset` used to delete it, which broke Docker's embedded DNS in
    # the docker lab on GitHub's runners.
    tables = json.loads(host.check_output("nft -j list tables"))["nftables"]
    names = {(t["table"]["family"], t["table"]["name"]) for t in tables if "table" in t}
    assert ("ip", "foreign_dns") in names
    assert ("inet", "filter") in names


def rule_by_comment(rules, comment):
    matches = [r for r in rules if r.get("comment") == comment]
    assert len(matches) == 1, f"expected one rule commented {comment!r}"
    return matches[0]


def match_value(rule, field):
    """Return the right-hand side of the match on payload field `field` (saddr, dport)."""
    for expr in rule["expr"]:
        match = expr.get("match")
        if match and match["left"].get("payload", {}).get("field") == field:
            return match["right"]
    return None


def test_service_enabled(host):
    nft = host.service("nftables")
    assert nft.is_enabled
    assert nft.is_running


def test_default_policies(ruleset):
    chains, _ = ruleset
    assert chains["input"]["policy"] == "drop"
    assert chains["forward"]["policy"] == "drop"
    assert chains["output"]["policy"] == "accept"


def test_ssh_open_to_anyone(ruleset):
    _, rules = ruleset
    ssh = rule_by_comment(rules, "ssh")
    assert match_value(ssh, "dport") == 22
    assert match_value(ssh, "saddr") is None


def test_rule_restricted_to_source(ruleset):
    _, rules = ruleset
    app = rule_by_comment(rules, "app-from-lb")
    assert match_value(app, "dport") == 8000
    # nft stores a one-element set as a plain value
    assert match_value(app, "saddr") == "192.0.2.10"


def test_multi_port_dual_stack_rule_is_split_per_family(ruleset):
    _, rules = ruleset
    v4 = rule_by_comment(rules, "metrics")
    v6 = rule_by_comment(rules, "metrics (v6)")
    for rule in (v4, v6):
        assert match_value(rule, "dport") == {"set": [9100, 9187]}
    assert "192.0.2.0" in json.dumps(match_value(v4, "saddr"))
    assert "2001:db8::" in json.dumps(match_value(v6, "saddr"))


def test_udp_rule(ruleset):
    _, rules = ruleset
    dns = rule_by_comment(rules, "dns")
    assert '"protocol": "udp"' in json.dumps(dns)


def test_config_on_disk_is_valid(host):
    path = "/etc/nftables.conf" if host.system_info.distribution == "debian" else "/etc/sysconfig/nftables.conf"
    assert host.file(path).mode == 0o600
    assert host.run(f"nft -c -f {path}").rc == 0


def test_firewalld_not_running(host):
    assert not host.service("firewalld").is_running
