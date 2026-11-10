# 3. Rolling deploy with drain, and backward-compatible migrations

Date: 2026-11-10 · Status: accepted

## Context

There are two app servers behind nginx. Restarting both at once is downtime;
restarting one without telling nginx sends some requests to a dead backend.

## Decision

`playbooks/deploy.yml` runs with `serial: 1` and `max_fail_percentage: 0`.
For each host:

1. Build the release (still in the load balancer).
2. Run `alembic upgrade head` (the first host does the work, later hosts see
   the schema already at head).
3. Mark the host `down` in the nginx upstream and reload nginx. A reload
   starts new workers with the new config; old workers finish the requests
   they already accepted. Nothing in flight is dropped.
4. Switch the symlink, restart, wait for `/health`, then run a smoke test.
5. Put the host back into the upstream.
6. If any step after the drain fails: point the symlink back, restart, check
   health, put the host back, and fail the play so the remaining hosts stay
   on the old version.

As a second line of defence, nginx retries idempotent requests on the other
backend (`proxy_next_upstream`) and the upstream uses a shared memory `zone`
so all workers agree on which backend is failing.

## Migrations

During a rolling deploy the old and the new version run against the same
database at the same time. So migrations must be backward compatible
(expand/contract):

- add a nullable column or one with a default, deploy code that writes it,
  backfill, and only later make it `NOT NULL`;
- never rename or drop a column in the same release that stops using it;
  drop it one release later.

A failed deploy does not downgrade the schema: with expand/contract the old
code still works on the new schema, and automatic downgrades lose data.

## Consequences

- Measured in the docker lab: 1938 requests during a full deploy, 0 failed,
  and nginx needed 0 retries (the drain alone was enough).
- The drain only happens when the release changes. A config-only change (env
  file, unit file) restarts the service without a drain; GETs are retried on
  the other backend, but an in-flight POST could fail.
