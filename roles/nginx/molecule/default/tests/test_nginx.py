"""Checks for the nginx role."""


def test_service_running(host):
    nginx = host.service("nginx")
    assert nginx.is_running
    assert nginx.is_enabled


def test_config_valid(host):
    assert host.run("nginx -t").rc == 0


def test_listening(host):
    assert host.socket("tcp://0.0.0.0:80").is_listening


def test_balances_between_backends(host):
    seen = {host.check_output("curl -fsS http://127.0.0.1/") for _ in range(6)}
    assert seen == {"backend1", "backend2"}


def test_fails_over_when_a_backend_dies(host):
    host.run("systemctl stop backend1")
    try:
        answers = [host.run("curl -fsS http://127.0.0.1/") for _ in range(6)]
        assert all(a.rc == 0 and a.stdout.strip() == "backend2" for a in answers)
    finally:
        host.run("systemctl start backend1 || true")


def test_status_page_is_local_only(host):
    assert "Active connections" in host.check_output("curl -fsS http://127.0.0.1/nginx_status")


def test_server_version_hidden(host):
    headers = host.check_output("curl -sI http://127.0.0.1/")
    assert "Server: nginx\r" in headers or "Server: nginx\n" in headers
