# 2. Release directories and a symlink switch for the app

Date: 2026-11-10 · Status: accepted

## Context

The app (`rest-api-transport-firm`) is a Python service. Updating it in
place (`git pull` + `pip install` in one directory) leaves a window where the
code and the dependencies do not match, and a rollback means reinstalling the
previous version under pressure.

## Decision

- Every version is checked out into `/opt/transport-api/releases/<version>`
  with its own virtualenv.
- `/opt/transport-api/current` is a symlink to the active release. systemd
  starts `current/.venv/bin/uvicorn`, so switching is "move the symlink,
  restart". Ansible replaces the link with `rename(2)`, which is atomic.
- `app_version` must be a full commit SHA or a version tag. A branch name
  would make the same version string mean different code on different days.
- Code is owned by root and only readable by the `transport` service
  account; the service cannot modify itself.
- The last 3 releases are kept; the running one and the rollback target are
  never deleted.

## Consequences

- Rollback is instant and does not touch the network or PyPI.
- Each release costs disk space for its code and venv (~100 MB here).
- Building a release happens while the host still serves the old one, so the
  time a host spends out of the load balancer is only the restart.
