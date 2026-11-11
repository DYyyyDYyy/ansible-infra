"""Checks for the node_exporter role."""

BINARY = "/opt/node_exporter-1.12.1/node_exporter"


def metrics(host):
    return host.check_output("curl -fsS http://127.0.0.1:9100/metrics")


def test_service_running_unprivileged(host):
    service = host.service("node_exporter")
    assert service.is_running
    assert service.is_enabled
    assert host.check_output("systemctl show -p User --value node_exporter") == "node_exporter"


def test_listens_only_where_configured(host):
    assert host.socket("tcp://127.0.0.1:9100").is_listening
    assert not host.socket("tcp://0.0.0.0:9100").is_listening


def test_binary_is_root_owned_and_not_writable(host):
    binary = host.file(BINARY)
    assert binary.user == "root"
    assert binary.mode & 0o022 == 0
    assert host.file("/opt/node_exporter-1.12.1").mode & 0o022 == 0


def test_exports_host_metrics(host):
    out = metrics(host)
    assert "node_load1 " in out
    assert 'node_exporter_build_info{' in out


def test_textfile_collector(host):
    assert "molecule_test_metric 42" in metrics(host)
    assert host.file("/var/lib/node_exporter/textfile").user == "root"


def test_sandboxed(host):
    def prop(name):
        return host.check_output(f"systemctl show -p {name} --value node_exporter")

    assert prop("NoNewPrivileges") == "yes"
    assert prop("ProtectSystem") == "strict"
