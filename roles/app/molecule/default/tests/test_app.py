"""Checks for the app role: release layout, sandboxing and a live API."""

import json

import pytest

RELEASE = "/opt/transport-api/releases/fd3fea549ecb92ee7ff98fd5638e0ccfcbc4aabc"


def test_service_running_as_service_account(host):
    service = host.service("transport-api")
    assert service.is_running
    assert service.is_enabled
    users = host.check_output("ps -o user= -C uvicorn --no-headers || ps -eo user,args | grep [u]vicorn")
    assert "transport" in users


def test_current_points_to_release(host):
    current = host.file("/opt/transport-api/current")
    assert current.is_symlink
    assert current.linked_to == RELEASE


def test_code_is_not_writable_by_the_app(host):
    release = host.file(RELEASE)
    assert release.user == "root"
    assert host.run(f"sudo -u transport touch {RELEASE}/app/pwned.py").rc != 0


def test_env_file_is_private(host):
    env = host.file("/etc/transport-api.env")
    assert env.mode == 0o640
    assert env.group == "transport"
    assert host.run("sudo -u nobody cat /etc/transport-api.env").rc != 0


def test_health_endpoint(host):
    out = host.check_output("curl -fsS http://127.0.0.1:8000/health")
    assert json.loads(out) == {"status": "ok"}


def test_api_reads_from_database(host):
    # Only works if migrations ran and the DB credentials are right.
    out = host.check_output("curl -fsS http://127.0.0.1:8000/vehicles")
    assert isinstance(json.loads(out), list)


def test_migrations_at_head(host):
    out = host.check_output(
        "sudo -u postgres psql -d transport_firm -tAc 'select version_num from alembic_version'"
    )
    assert out.strip() == "0002"


@pytest.mark.parametrize(
    "prop,expected",
    [
        ("NoNewPrivileges", "yes"),
        ("ProtectSystem", "strict"),
        ("ProtectHome", "yes"),
        ("PrivateTmp", "yes"),
        ("User", "transport"),
    ],
)
def test_unit_sandboxing(host, prop, expected):
    value = host.check_output(f"systemctl show -p {prop} --value transport-api")
    assert value == expected
