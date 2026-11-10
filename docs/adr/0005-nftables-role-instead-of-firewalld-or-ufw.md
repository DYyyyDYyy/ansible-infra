# 5. One nftables ruleset instead of firewalld or ufw

Date: 2026-11-10 · Status: accepted

## Context

Debian usually gets ufw or plain nftables, Rocky ships firewalld. Supporting
both front-ends means two different models of the same rules.

## Decision

Write the ruleset directly in nftables syntax from a template, on both
distros, and stop and mask firewalld where it exists.

- Inbound policy `drop`; loopback, established/related, ICMP and SSH are
  always allowed; everything else comes from `firewall_rules`.
- Sources are computed from inventory groups (`app` may reach `db:5432`,
  `lb` may reach `app:8000`), so adding a host updates every rule.
- The file is checked with `nft -c` before it is written, and it starts with
  `flush ruleset`, so a reload replaces the ruleset in one transaction.
- One nft rule cannot match both `ip saddr` and `ip6 saddr`, so rules with
  mixed sources are split per address family.

## Consequences

- One model to understand and test.
- `flush ruleset` also removes chains created by Docker, Podman or libvirt;
  the role must not be applied to hosts that run containers or VMs.
