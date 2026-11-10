"""Checks for the postgresql role."""

PSQL = "PGPASSWORD={password} psql -h 127.0.0.1 -U transport -d transport_firm -tAc '{sql}'"


def psql(host, sql, password="molecule-secret"):
    return host.run(PSQL.format(password=password, sql=sql))


def test_service_running(host):
    service = host.service("postgresql")
    assert service.is_running
    assert service.is_enabled


def test_listens_on_all_addresses(host):
    assert host.socket("tcp://0.0.0.0:5432").is_listening


def test_app_user_can_log_in_with_password(host):
    result = psql(host, "select current_user")
    assert result.rc == 0, result.stderr
    assert result.stdout.strip() == "transport"


def test_wrong_password_is_rejected(host):
    assert psql(host, "select 1", password="wrong").rc != 0


def test_database_owner(host):
    owner = psql(host, "select pg_get_userbyid(datdba) from pg_database where datname = current_database()")
    assert owner.stdout.strip() == "transport"


def test_password_stored_as_scram(host):
    out = host.run("sudo -u postgres psql -tAc \"select rolpassword from pg_authid where rolname = 'transport'\"")
    assert out.stdout.startswith("SCRAM-SHA-256$")


def test_dropin_settings_applied(host):
    assert psql(host, "show max_connections").stdout.strip() == "50"
    assert psql(host, "show log_min_duration_statement").stdout.strip() == "500ms"


def test_hba_entry_present(host):
    rules = host.run("sudo -u postgres psql -tAc \"select address, netmask from pg_hba_file_rules where 'transport_firm' = any(database)\"")
    assert "192.0.2.0|255.255.255.0" in rules.stdout
    assert "198.51.100.7|255.255.255.255" in rules.stdout
