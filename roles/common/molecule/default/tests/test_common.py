"""Checks for the common role, run by Molecule through testinfra."""

TEST_KEY = "AAAAC3NzaC1lZDI1NTE5AAAAIPGUGm97s3pt+RQKVDvbnWCqbt4VID1iN9qxTVl3YLvt"


def test_admin_user_is_in_admin_group(host):
    user = host.user("alice")
    assert user.exists
    assert "admins" in user.groups
    assert user.shell == "/bin/bash"


def test_authorized_key_installed(host):
    keys = host.file("/home/alice/.ssh/authorized_keys")
    assert keys.exists
    assert keys.user == "alice"
    assert keys.mode == 0o600
    assert TEST_KEY in keys.content_string


def test_sudoers_dropin_is_valid(host):
    sudoers = host.file("/etc/sudoers.d/admins")
    assert sudoers.mode == 0o440
    assert host.run("visudo -c").rc == 0


def test_admin_can_sudo_without_password(host):
    # -n: fail instead of prompting for a password
    result = host.run("sudo -u alice sudo -n true")
    account = host.run(
        "chage -l alice; getent shadow alice | cut -d: -f2-; "
        "journalctl --no-pager -n 15 _COMM=sudo; rpm -q pam sudo shadow-utils 2>/dev/null; "
        "ls -l /etc/shadow /usr/bin/sudo /usr/sbin/unix_chkpwd; getcap /usr/sbin/unix_chkpwd; "
        "grep -E '^(passwd|shadow):' /etc/nsswitch.conf; grep -E '^account' /etc/pam.d/system-auth; "
        "sudo -u alice grep -E '^Cap(Prm|Eff|Bnd)' /proc/self/status; grep -E '^(Cap|NoNewPrivs|Seccomp)' /proc/1/status"
    ).stdout
    assert result.rc == 0, f"{result.stderr}\n{account}"


def test_sshd_effective_config(host):
    # `sshd -T` prints the config sshd would actually use, after all includes.
    effective = host.check_output("sshd -T").splitlines()
    for line in (
        "permitrootlogin no",
        "passwordauthentication no",
        "kbdinteractiveauthentication no",
        "maxauthtries 3",
        "x11forwarding no",
        "allowtcpforwarding no",
    ):
        assert line in effective, line


def test_sshd_running(host):
    name = "ssh" if host.system_info.distribution == "debian" else "sshd"
    service = host.service(name)
    assert service.is_running
    assert service.is_enabled


def test_automatic_security_updates(host):
    if host.system_info.distribution == "debian":
        conf = host.file("/etc/apt/apt.conf.d/20auto-upgrades").content_string
        assert 'Unattended-Upgrade "1"' in conf
        assert host.package("unattended-upgrades").is_installed
    else:
        conf = host.file("/etc/dnf/automatic.conf").content_string
        assert "upgrade_type = security" in conf
        assert host.service("dnf-automatic.timer").is_enabled
