"""Checks for the postgres_exporter role."""

import pytest


@pytest.fixture(scope="module")
def metrics(host):
    return host.check_output("curl -fsS http://127.0.0.1:9187/metrics")


def test_service_running_unprivileged(host):
    service = host.service("postgres_exporter")
    assert service.is_running
    assert service.is_enabled
    assert host.check_output("systemctl show -p User --value postgres_exporter") == "postgres_exporter"
    assert host.socket("tcp://127.0.0.1:9187").is_listening


def test_reaches_postgresql(metrics):
    assert "\npg_up 1\n" in metrics


def test_reads_statistics(metrics):
    assert "pg_stat_database_xact_commit{" in metrics


def test_role_is_monitoring_only(host):
    query = (
        "select rolsuper, pg_has_role('postgres_exporter', 'pg_monitor', 'member') "
        "from pg_roles where rolname = 'postgres_exporter'"
    )
    assert host.check_output(f'sudo -u postgres psql -tAc "{query}"') == "f|t"


def test_no_password_stored(host):
    out = host.check_output(
        "sudo -u postgres psql -tAc \"select rolpassword is null from pg_authid where rolname = 'postgres_exporter'\""
    )
    assert out == "t"
