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
- The file is checked with `nft -c` before it is written. It replaces only
  the role's own table (`table inet filter` / `delete table inet filter` /
  the new table), in one transaction, and the handler loads it with
  `nft -f` rather than `systemctl reload nftables`.
- One nft rule cannot match both `ip saddr` and `ip6 saddr`, so rules with
  mixed sources are split per address family.

## Consequences

- One model to understand and test.
- The first version started with `flush ruleset`. The first GitHub Actions
  run showed what that costs: on Ubuntu 24.04 Docker writes its embedded
  DNS rules (a DNAT to 127.0.0.11 inside every container) through
  iptables-nft, so the flush deleted them and the lab containers lost DNS
  right after the firewall role. Locally Docker used iptables-legacy, which
  nft cannot see, so nothing broke. Molecule now creates a foreign NAT table
  before converging and checks that it survives. The same test then failed
  only on Rocky: EL's `nftables.service` reloads with
  `nft 'flush ruleset; include ...'`, hence `nft -f` in the handler.
- Tables of other tools now survive, but the forward chain still drops by
  default, so hosts that route traffic for containers or VMs need more than
  this role.
