# 7. Prometheus monitoring from pinned upstream binaries

Date: 2026-11-11 · Status: accepted

## Context

The stack needs to say when something breaks: a host or exporter gone, the
API failing through the load balancer, PostgreSQL down, a disk filling up,
backups no longer running. Nobody watches dashboards in a lab, so alerts
matter more than graphs.

## Decision

- **Prometheus + Alertmanager + blackbox_exporter** on `ops`,
  **node_exporter** on every host, **postgres_exporter** on `db`.
- **Upstream release tarballs, pinned by version and SHA256**, the same on
  Debian and Rocky. Rocky has no node_exporter or Prometheus packages
  without EPEL, and Debian's are older than upstream. The checksums are
  stored in the role defaults rather than fetched from the release page, so
  a tampered release fails the download instead of being trusted. A small
  helper role, `upstream_binary`, downloads each tarball once on the
  controller, verifies it, and unpacks it into `/opt/<name>-<version>`;
  units run the versioned path, so a version bump rewrites the unit and
  restarts the service.
- **Scrape targets come from inventory groups**: every host for
  node_exporter, `database` for postgres_exporter, the load balancer's
  `/health` and `/vehicles` for the blackbox probe. Adding a host to the
  inventory adds it to monitoring.
- **Alerts:** `InstanceDown`, `AppEndpointDown`, `PostgresDown`,
  `HostDiskAlmostFull`, `BackupTooOld` and `BackupMissing`. The last one
  exists because `BackupTooOld` compares a timestamp: a backup that never
  succeeded has no timestamp, and the comparison silently returns nothing.
  The `for:` duration is a variable, 5 minutes by default and 30 seconds in
  the labs.
- **Every rule has a unit test** (`promtool test rules`), run by the role on
  every converge, before Prometheus is reloaded. Configs are checked with
  `promtool check config`, `promtool check rules`, `amtool check-config`
  and `blackbox_exporter --config.check` as the `validate` step of the
  template, so a broken file never reaches the disk.
- **Alertmanager → Telegram** when `vault_telegram_bot_token` is set;
  otherwise a receiver with no integrations, so alerts are still visible in
  the UI and API.
- **Network:** exporters listen on the private IP and the firewall lets only
  `ops` reach 9100 and 9187. Prometheus, Alertmanager and blackbox listen
  on `127.0.0.1` on `ops`; the web UIs are reached with `ssh -L`, which the
  common role allows on this host only (`AllowTcpForwarding local`).
- **The whole path is tested:** `make alert-test` stops the API on both app
  servers and postgres_exporter on `db`, waits until `AppEndpointDown` and
  `InstanceDown` are active in Alertmanager's API, starts everything again
  and waits for them to resolve. It runs in CI.

Not chosen: Grafana (dashboards are not what this project is about, and
Prometheus' own UI is enough to look at a query); Loki and log alerts;
Prometheus' agent mode or remote write (one Prometheus is enough here).

## Consequences

- Every service runs under its own account with systemd sandboxing. The
  syscall filter needed one exception: node_exporter's `timex` collector
  calls `adjtimex(2)`, which is in `@privileged`, and seccomp killed the
  process on its first scrape. Only that call is allowed back.
- Upgrades are manual: change version and checksum in the role defaults.
  Dependabot does not see them.
- Alertmanager has no HA peer (`--cluster.listen-address=` disables the
  gossip port). If `ops` is down, nothing alerts; a dead man's switch to an
  external service would cover that.
- Only amd64 is supported, because only amd64 checksums are pinned.
