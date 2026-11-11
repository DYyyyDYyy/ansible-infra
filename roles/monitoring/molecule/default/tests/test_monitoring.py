"""Checks for the monitoring role: services, generated config, rule tests and a real alert."""

import json
import time

import pytest

PROM = "http://127.0.0.1:9090"
AM = "http://127.0.0.1:9093"


def get_json(host, url):
    return json.loads(host.check_output(f"curl -fsS '{url}'"))


@pytest.mark.parametrize(
    "service,port",
    [("prometheus", 9090), ("alertmanager", 9093), ("blackbox_exporter", 9115)],
)
def test_service_listens_on_localhost_only(host, service, port):
    assert host.service(service).is_running
    assert host.service(service).is_enabled
    assert host.check_output(f"systemctl show -p User --value {service}") == service
    assert host.socket(f"tcp://127.0.0.1:{port}").is_listening
    assert not host.socket(f"tcp://0.0.0.0:{port}").is_listening


def test_alertmanager_gossip_port_disabled(host):
    assert not host.socket("tcp://0.0.0.0:9094").is_listening


def test_config_and_rules_are_valid(host):
    host.check_output("promtool check config /etc/prometheus/prometheus.yml")
    host.check_output("amtool check-config /etc/alertmanager/alertmanager.yml")


def test_rule_unit_tests_pass(host):
    out = host.run("cd /etc/prometheus/tests && promtool test rules alerts_test.yml")
    assert out.rc == 0, out.stdout + out.stderr
    assert "SUCCESS" in out.stdout


def test_null_receiver_without_telegram_token(host):
    config = host.file("/etc/alertmanager/alertmanager.yml")
    assert "receiver: none" in config.content_string
    assert "telegram" not in config.content_string
    assert config.mode == 0o640


def wait_for(predicate, timeout=90):
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(2)
    return None


def test_inventory_target_is_scraped(host):
    def node_up():
        result = get_json(host, PROM + "/api/v1/query?query=up%7Bjob%3D%22node%22%7D")["data"]["result"]
        return result and result[0]["value"][1] == "1" and result[0]["metric"]["instance"] == "self"

    assert wait_for(node_up)


def test_failing_probe_reaches_alertmanager(host):
    def firing():
        alerts = get_json(host, AM + "/api/v2/alerts?filter=alertname%3D%22AppEndpointDown%22")
        return [a for a in alerts if a["status"]["state"] == "active"]

    alerts = wait_for(firing)
    assert alerts, "AppEndpointDown never reached Alertmanager"
    assert [a["labels"]["instance"] for a in alerts] == ["http://127.0.0.1:9/nothing-here"]
