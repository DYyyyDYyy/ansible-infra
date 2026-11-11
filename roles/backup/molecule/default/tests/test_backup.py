"""Checks for the backup role: timer, snapshot, metric, and a real restore."""

import json
import time

import pytest

RESTIC = "set -a && . /etc/restic/backup.env && restic --no-cache "
PSQL = "sudo -u postgres psql -tAc "


@pytest.fixture(scope="module")
def restored(host):
    """Restore the latest snapshot into a scratch database, drop it afterwards."""
    host.run(PSQL + "'drop database if exists restore_test'")
    host.check_output(PSQL + "'create database restore_test'")
    result = host.run(
        "bash -o pipefail -c '" + RESTIC + "dump --tag transport_firm latest /transport_firm.dump"
        " | sudo -u postgres pg_restore --no-owner --exit-on-error -d restore_test'"
    )
    assert result.rc == 0, result.stderr
    yield host
    host.run(PSQL + "'drop database restore_test'")


def test_timer_enabled(host):
    timer = host.service("backup.timer")
    assert timer.is_enabled
    assert timer.is_running
    assert "hourly" in host.file("/etc/systemd/system/backup.timer").content_string


def test_credentials_are_root_only(host):
    env = host.file("/etc/restic/backup.env")
    assert env.user == "root"
    assert env.mode == 0o600
    assert host.run("sudo -u backup_pg cat /etc/restic/backup.env").rc != 0


def test_backup_role_cannot_write(host):
    result = host.run("sudo -u backup_pg psql -d transport_firm -c \"insert into clients (name) values ('x')\"")
    assert result.rc != 0
    assert "permission denied" in result.stderr


def test_first_snapshot_taken_during_converge(host):
    snapshots = json.loads(host.check_output(RESTIC + "snapshots --json --tag postgres"))
    assert snapshots
    assert snapshots[-1]["paths"] == ["/transport_firm.dump"]


def test_service_run_updates_metric(host):
    before = time.time()
    host.check_output("systemctl start backup.service")
    metric = host.file("/var/lib/node_exporter/textfile/backup.prom")
    assert metric.mode == 0o644
    value = [line for line in metric.content_string.splitlines() if line.startswith("backup_last_success")]
    assert float(value[0].split()[1]) >= int(before)


def test_failed_dump_is_not_saved(host):
    count = len(json.loads(host.check_output(RESTIC + "snapshots --json")))
    result = host.run(
        RESTIC + "backup --stdin-from-command --stdin-filename broken.dump -- pg_dump no_such_database"
    )
    assert result.rc != 0
    assert len(json.loads(host.check_output(RESTIC + "snapshots --json"))) == count


def test_restore_has_the_same_rows(restored):
    live = restored.check_output(PSQL + "'select count(*) from clients' transport_firm")
    copy = restored.check_output(PSQL + "'select count(*) from clients' restore_test")
    assert live == copy == "25"
