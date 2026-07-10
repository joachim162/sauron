#import "defs.typ": note, warn

= DHCP: How It Works, Through Sauron's Eyes <dhcp>

DHCP automates network configuration: a booting machine broadcasts a
request and receives an IP address, netmask, router, DNS servers, and
arbitrary other options, leased for a limited time. Sauron's job is to
generate the ISC dhcpd server's entire configuration — subnets, pools,
reservations, classes, options, failover — from the same host database
that drives DNS.

== DHCPv4: the DORA exchange

A client with no address yet uses broadcasts (UDP 67 server / 68
client):

+ *DISCOVER* — client broadcasts "anyone out there?", identifying itself
  by MAC address (and optionally a client-id).
+ *OFFER* — each server proposes an address plus options.
+ *REQUEST* — the client broadcasts which offer it accepts (so losing
  servers can retract).
+ *ACK* — the chosen server confirms and starts the *lease* clock.

At half the lease time the client unicasts a renewal REQUEST; at 87.5%
it falls back to broadcast rebinding; if the lease expires it starts
over. This lease lifecycle is why Sauron's `leases` table and the
`hosts.dhcp_date` / `dhcp_last` columns exist: `update-dhcp-info`
parses the live server's syslog/leases file and writes back *when each
known MAC was last seen*, powering the `expire-hosts` reaper that
retires machines which vanished from the network.

*Relay agents* make one server serve many subnets: a router forwards the
client's broadcast as unicast, recording the subnet's address in the
`giaddr` field. The server picks the matching `subnet {}` declaration by
`giaddr` — which is why dhcpd needs an explicit subnet declaration for
every network it serves, and why Sauron's `nets` table *is* the subnet
map. When one wire carries several IP subnets, dhcpd groups them in a
`shared-network {}` block — Sauron generates those from VLANs
(`dhcp_mode = 0`) since a VLAN is exactly "one broadcast domain".

== How addresses get assigned

dhcpd distinguishes three assignment styles, and each maps to a Sauron
structure:

#table(
  columns: (auto, auto, 1fr),
  table.header([Style], [dhcpd construct], [Sauron source]),
  [Static reservation], [`host { hardware ethernet …; fixed-address …; }`],
    [A host row with `ether` set and an IP: the machine always gets its
    registered address. The backbone of a managed campus network —
    DNS and DHCP agree because they are the same row.],
  [Dynamic pool], [`pool { range a b; }`], [Host groups of type 2
    ("dynamic address pool"): their `dhcp_entries` carry the `range`
    lines. Unregistered machines get whatever is free; the pool can
    `deny unknown-clients` or be class-restricted.],
  [Class-based], [`class` / `subclass` matching], [Groups of type 3/103
    become `class {}` declarations subclassed by MAC — used to steer
    device categories (phones, printers) to different pools/options.],
)

Note the division of labor with Sauron's own auto-assignment
(@autoassign): `get_free_ip_by_net` picks a *permanent* address at
registration time (a management-plane decision recorded in
`a_entries`), while dhcpd pools assign *temporary* addresses at boot
time (a data-plane decision recorded only in `leases`). The
`nets.range_start`/`range_end` columns feed the former; `range` lines in
pool groups feed the latter — do not confuse them.

== Options: strings all the way down

Everything a client learns beyond its address is an *option* (router,
domain-name-servers, ntp-servers, TFTP boot filename, …). Sauron does
not model options structurally: `dhcp_entries.dhcp` rows are *literal
dhcpd.conf lines* (`option routers 10.0.0.1;`) attached at any level —
server (global), net (subnet), vlan (shared-network), group, or host —
and emitted verbatim into the corresponding block. dhcpd's scoping does
the rest: the most specific block wins. Host-level lines support macro
expansion (`%{domain}`, `%{ether}`, `%{fqdn}`, `%{host}`).

The price of this design is that Sauron cannot validate option syntax —
a typo in a `dhcp_l` line surfaces only when dhcpd parses the generated
file. This is why running the generator with `--check` (`dhcpd -t`)
before deployment is non-negotiable, and why the API should pass these
strings through untouched rather than attempting cleverness.

== Failover

ISC dhcpd's failover protocol lets two servers share pools: they split
free addresses (`split 128` ≈ 50/50), exchange binding updates, and
cover for each other (governed by `mclt`, the maximum client lead time).
Sauron models this with server-level flags (`dhcp_flags` bit 0x02) and
the `df_*` parameter columns; the generator emits the `failover peer`
block and marks pools failover-aware. Only *dynamic pools* participate —
static reservations are stateless and simply exist in both servers'
configs.

== DHCPv6

IPv6 changes the mechanics more than the concepts:

- *Transport*: UDP 546/547 over link-local multicast — no broadcasts,
  no giaddr (relays use link-address instead).
- *Exchange*: SOLICIT → ADVERTISE → REQUEST → REPLY (plus a
  rapid-commit two-message variant) — same shape as DORA.
- *Identity*: clients are identified not by MAC but by *DUID* (a stable
  per-machine identifier) plus *IAID* (per-interface identity
  association id). This is exactly why `hosts` grew `duid` and `iaid`
  columns with the `UNIQUE(zone, duid, COALESCE(iaid,0))` constraint,
  and why host types 9/101 exist for pre-registered v6 reservations.
  Generated reservations match on
  `host-identifier option dhcp6.client-id <duid>`.
- *Addresses*: hosts commonly hold several (SLAAC + DHCPv6 + privacy);
  DHCPv6 may delegate whole prefixes (IA_PD). Sauron's MAC-based and
  IPv4-based auto-assignment policies (20/30) exist to keep *managed*
  v6 addresses deterministic and correlatable.
- *Configuration*: `make_dhcp6` mirrors the v4 generator with
  `subnet6`, `range6`, the `dhcp_l6`/`dhcp6` option families, and the
  `df_*6` failover columns.

A dual-stack host is *one* Sauron host row with both A and AAAA
`a_entries`, one MAC, one DUID — a single source of truth for four
protocols (DNS forward/reverse, DHCPv4, DHCPv6).

== The feedback loop, end to end

```
 register host (CGI/API)          sauron --dhcp --check
 hosts + a_entries + ether  ───►  dhcpd.conf ───► push ───► dhcpd
        ▲                                                    │
        │ dhcp_date/dhcp_last, leases                        │ syslog,
        └──────────────  update-dhcp-info  ◄─────────────────┘ leases file
                │
                └──► expire-hosts ──► hosts.expiration ──► sauron --clean
```

This loop is the operational heart of Sauron as an IPAM: registration
flows down to the daemons; observed reality flows back up into
`leases`/`dhcp_last`; and lifecycle tooling retires what no longer
exists. An API that exposes hosts should also expose this telemetry
(last-seen, lease state) — administrators use it constantly.
