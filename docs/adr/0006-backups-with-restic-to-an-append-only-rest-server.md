# 6. Backups with restic to an append-only rest-server on a separate host

Date: 2026-11-11 · Status: accepted

## Context

The database needs backups that survive the loss of the `db` host, that a
compromised `db` cannot destroy, and that are proven to restore.

The original plan was restic to MinIO (S3) on a fifth host, `ops`. Checking
MinIO in November 2026 changed that: the GitHub repository is archived, the
last release (2025-10-15) has no binaries attached and tells users to build
it with `go install`, and the community edition lost its admin console
earlier in 2025. Building an archived AGPL server from source to store
backups is the wrong kind of dependency.

Options considered:

| Option | For | Against |
|---|---|---|
| MinIO | S3 API, well known | archived, no official binaries, licence churn |
| Garage (S3) | maintained, S3 API, single binary | an S3 cluster layout to learn and operate for one client |
| restic rest-server | maintained by the restic project, single binary, made for exactly this | restic-only protocol |
| SSH/SFTP to `ops` | nothing to install | a client with SSH access can delete everything |

## Decision

- **restic** on `db`, from the Debian repositories (gets security updates
  with the rest of the system).
- **rest-server** on `ops`, upstream release pinned by SHA256, started with
  `--append-only --private-repos` and bcrypt passwords in `.htpasswd`.
- Every hour a systemd timer runs `restic backup --stdin-from-command --
  pg_dump --format=custom <db>`. With `--stdin-from-command` restic runs
  `pg_dump` itself and saves no snapshot if it exits non-zero; the obvious
  `pg_dump | restic backup --stdin` would save a truncated dump as if it
  were good.
- `pg_dump` runs as a dedicated `backup_pg` role with `pg_read_all_data`:
  it can read every table and write none. It logs in over the Unix socket
  with peer authentication, so there is no database password to store.
- **Retention runs on the server.** Clients are append-only, so they cannot
  run `forget`/`prune`. A `restic-maintenance@<repo>.timer` on `ops` runs
  `forget --prune --keep-hourly 24 --keep-daily 7` and `restic check`
  directly on the repository directory.
- After each successful run the job writes
  `backup_last_success_timestamp_seconds` for node_exporter's textfile
  collector; Prometheus alerts when it is older than two hours or missing.
- `make restore-test` (in CI) restores the latest snapshot into a scratch
  database and compares `count(*)` of every table with the live one.

## Consequences

- A compromised `db` (or ransomware on it) can add snapshots but cannot
  delete or overwrite old ones: the server answers `403` to every `DELETE`
  except lock files. Its restic credentials are still enough to *read* the
  backups.
- `ops` holds the repository password, because pruning needs it. `ops` is
  therefore the most trusted host: it can decrypt every backup, and only
  `db` may reach its port 8000. A production setup would add a second,
  off-site copy (`restic copy` to object storage in another account).
- Transport is plain HTTP on the private network. restic encrypts and
  authenticates the data itself, so this exposes only the HTTP password;
  TLS on rest-server (`--tls`) is the next step outside a lab.
- Roles and passwords (`pg_dumpall --globals-only`) are not in the backup:
  `backup_pg` is not a superuser and cannot read them. They are recreated by
  Ansible from the vault, which is the source of truth for them anyway.
- Hourly dumps mean up to an hour of data loss (RPO 1 h). Lower RPO needs
  WAL archiving (pgBackRest, WAL-G), a different tool and a different ADR.
- The backup roles are Debian-only: Rocky ships restic only in EPEL. The
  Rocky test image has EPEL enabled, so Molecule would pass on Rocky while a
  clean Rocky box would fail, the same trap as in ADR 4.
