# 4. A docker lab next to the Vagrant VMs

Date: 2026-11-10 · Status: accepted

## Context

The real target is four KVM VMs created by Vagrant. GitHub Actions runners
can do nested virtualisation only slowly, and not every machine has libvirt.

## Decision

Keep two inventories with the same groups and roles:

- `inventories/vagrant`: real VMs, SSH, SELinux enforcing on Rocky.
- `inventories/docker`: one privileged container per host running real
  systemd (images from geerlingguy), reached with `docker exec`.

The docker lab is created by `playbooks/lab.yml` with `community.docker`,
straight from `inventories/docker`, instead of a compose file. The inventory
is the single description of the lab, and nothing but the docker daemon is
needed.

## Consequences

The docker lab cannot test:

- SELinux (disabled in containers), so the `httpd_can_network_connect`
  boolean is only exercised on Vagrant;
- the kernel and boot process, swap, real disks;
- `sshd` as the transport (Ansible uses `docker exec`), although the sshd
  config is still validated with `sshd -t` and `sshd -T`.

- packages missing from a minimal OS image: the test images are built for
  Ansible and already contain Python libraries that modules need on the
  target. The first run on the Vagrant boxes found two such gaps that every
  container test had passed: `python3-libsemanage` for `seboolean` on Rocky
  and `python3-packaging` for the `pip` module. Both roles now install them.

nftables does work: each container has its own network namespace, so the
firewall rules are tested for real (the e2e checks that `lb` cannot reach
PostgreSQL on `db`).

So both environments stay: the docker lab on every push, the VMs before
calling a change done.
