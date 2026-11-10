# Runbook: a disk is full

**Symptoms:** the app returns 500s, PostgreSQL logs `No space left on device`,
`apt`/`dnf` fail, Ansible fails to copy files.

## 1. Find out what is full

```bash
df -h                 # which filesystem
df -i                 # inodes can run out while bytes are free
sudo du -xh --max-depth=2 / 2>/dev/null | sort -h | tail -20
```

## 2. Usual suspects on these hosts

| Where | What | Fix |
|---|---|---|
| `/var/log/journal` | systemd journal | `sudo journalctl --vacuum-size=200M` |
| `/var/log/nginx` | access logs on `lb` | check logrotate: `sudo logrotate -d /etc/logrotate.d/nginx` |
| `/opt/transport-api/releases` | old releases on `app*` | the role keeps 3; remove extras by hand, never `current` or the one before it |
| `/var/lib/postgresql`, `/var/lib/pgsql` | database on `db` | see below |
| `/var/cache/apt`, `/var/cache/dnf` | package caches | `sudo apt-get clean` / `sudo dnf clean all` |

## 3. If the database disk is full

Do **not** delete files from the data directory, and never touch `pg_wal/`
by hand. Free space elsewhere first so PostgreSQL can start, then:

```bash
sudo -u postgres psql -c "select pg_size_pretty(pg_database_size('transport_firm'))"
sudo -u postgres psql -d transport_firm -c "\dt+"
```

## 4. Afterwards

Write down what filled the disk and add the missing limit (log rotation,
journal size, release cleanup) to the relevant role so it does not happen
again.
