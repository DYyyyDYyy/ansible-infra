# Runbook: PostgreSQL does not start

**Symptoms:** the app health check passes but `/vehicles` returns 500,
`systemctl status postgresql` on `db` shows `failed`.

## 1. Read the actual error

```bash
sudo systemctl status postgresql
# Debian runs the cluster as a separate unit
sudo journalctl -u 'postgresql*' -n 50 --no-pager
# Debian
sudo tail -50 /var/log/postgresql/postgresql-17-main.log
# Rocky
sudo tail -50 /var/lib/pgsql/data/log/postgresql-*.log
```

## 2. Common causes

| Error | Cause | Fix |
|---|---|---|
| `could not bind IPv4 address "10.10.x.x"` | `listen_addresses` names an IP the host no longer has | fix `private_ip` in the inventory and re-run `site.yml` |
| `invalid value for parameter` / `syntax error in file` | bad value in `postgresql_settings` | check `conf.d/90-ansible.conf`, fix the variable, re-run |
| `could not load pg_hba.conf` | broken `pg_hba.conf` | Ansible templates it; re-run the playbook rather than editing by hand |
| `No space left on device` | full disk | see [disk-full.md](disk-full.md) |
| `lock file "postmaster.pid" already exists` | stale pid file after a crash | only if no `postgres` process runs: `pgrep -a postgres`, then remove the pid file |

## 3. Check the config before restarting

```bash
# Debian: shows the cluster state and the config it would use
pg_lsclusters
sudo -u postgres /usr/lib/postgresql/17/bin/postgres -C listen_addresses -D /etc/postgresql/17/main
```

## 4. Afterwards

Re-run `make provision` to make sure the host matches the code again, and
then `make check-idempotence` to confirm nothing else drifted.
