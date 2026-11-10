# 1. Configuration management on long-lived servers (mutable infrastructure)

Date: 2026-11-10 · Status: accepted

## Context

There are two common ways to keep servers in a known state:

- **Mutable**: servers live for a long time; a tool like Ansible converges
  them to the desired state on every run and changes them in place.
- **Immutable**: servers (or containers) are never changed; a new image is
  built for every change and replaces the old one (Packer + autoscaling
  groups, or Kubernetes with GitOps, as in my `gitops-platform` project).

This project targets the situation most companies still have: a handful of
VMs that someone has to patch, secure and deploy to.

## Decision

Use Ansible to converge the VMs in place. Every role must be idempotent: a
second run reports `changed=0`, and CI fails if it does not.

Application code is the one part handled in an immutable way: each version
gets its own release directory and is never modified (see ADR 2).

## Consequences

- Drift is possible between runs (someone edits a file by hand). Re-running
  `site.yml` fixes it; running it on a schedule would catch it early.
- The order of changes matters (packages before config, config before
  restart), which is why the roles use handlers and `flush_handlers`.
- Rebuilding a host from scratch must keep working, so the docker lab is
  recreated from nothing in CI on every push.
- Compared with immutable images, rollbacks of the OS layer are harder;
  rollbacks of the application are cheap (a symlink).
