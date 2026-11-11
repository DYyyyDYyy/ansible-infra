"""Checks for the restic_server role: auth, private repos, append-only, server-side retention."""

import json

import pytest

URL = "http://127.0.0.1:8000"
# A restic client, as the db host would use it.
CLIENT = (
    "RESTIC_REPOSITORY=rest:http://127.0.0.1:8000/db/ RESTIC_REST_USERNAME=db "
    "RESTIC_REST_PASSWORD=http-secret RESTIC_PASSWORD=repo-secret restic --no-cache "
)


def http_status(host, path, user=None, method="GET"):
    auth = f"-u {user}" if user else ""
    return host.check_output(f"curl -s -o /dev/null -w '%{{http_code}}' -X {method} {auth} {URL}{path}")


@pytest.fixture(scope="module")
def repo(host):
    """A repository with one snapshot, created through the server like a real client would."""
    if host.run(CLIENT + "cat config").rc != 0:
        host.check_output(CLIENT + "init")
    host.check_output(CLIENT + "backup --stdin-from-command --stdin-filename test.dump -- echo molecule")
    return host


def test_service_running_unprivileged(host):
    service = host.service("rest-server")
    assert service.is_running
    assert service.is_enabled
    assert host.check_output("systemctl show -p User --value rest-server") == "restic"
    assert host.socket("tcp://127.0.0.1:8000").is_listening


def test_htpasswd_is_private_and_hashed_with_bcrypt(host):
    htpasswd = host.file("/var/lib/restic-server/.htpasswd")
    assert htpasswd.mode == 0o600
    assert htpasswd.user == "restic"
    assert "http-secret" not in htpasswd.content_string
    assert htpasswd.content_string.startswith("db:$2y$")


def test_authentication_required(host):
    assert http_status(host, "/db/config") == "401"
    assert http_status(host, "/db/config", user="db:wrong") == "401"


def test_private_repos(host):
    # "other" is a valid user, but /db/ is not its repository
    assert http_status(host, "/db/config", user="other:other-secret") == "401"


def test_client_can_back_up(repo):
    snapshots = json.loads(repo.check_output(CLIENT + "snapshots --json"))
    assert len(snapshots) >= 1


def snapshot_count(host):
    return len(json.loads(host.check_output(CLIENT + "snapshots --json")))


def test_client_cannot_delete(repo):
    before = snapshot_count(repo)
    # restic only warns when the server refuses a removal and still exits 0,
    # so check what is left rather than the exit code.
    result = repo.run(CLIENT + "forget latest")
    assert "403" in result.stderr
    assert snapshot_count(repo) == before
    key = repo.check_output("ls /var/lib/restic-server/db/keys | head -1")
    assert http_status(repo, f"/db/keys/{key}", user="db:http-secret", method="DELETE") == "403"


def test_server_side_retention(repo):
    repo.check_output(CLIENT + "backup --stdin-from-command --stdin-filename test.dump -- echo second")
    assert repo.run("systemctl start restic-maintenance@db.service").rc == 0
    assert repo.service("restic-maintenance@db.timer").is_enabled
    log = repo.check_output("journalctl -u restic-maintenance@db.service --no-pager")
    assert "no errors were found" in log
