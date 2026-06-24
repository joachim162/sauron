# Sauron Domain Model
#fundamentals #dns #dhcp #data-model

Sauron is a database-driven configuration manager for BIND (DNS) and
ISC-DHCP. Everything it manages fits into a three-level hierarchy stored in
PostgreSQL; the `sauron` CLI exports that state into flat config files that
BIND and DHCPD read.

```
Server  ──contains──►  Zone  ──contains──►  Host
```

See [[High-Level-Operation]] for the export/push/reload lifecycle.

---

## Server

A **Server** is a logical representation of one BIND + ISC-DHCP instance.
It is **not** necessarily a physical machine — it is Sauron's configuration
scope for one daemon pair.

Each server owns:
- Its global BIND options (`named.conf` globals — ACLs, forwarders,
  `listen-on`, logging, DHCP globals, etc.)
- All zones that will appear in that `named.conf`

The server record stores things like the `directory`, `pid_file`, ACL lists
(`allow_query`, `allow_transfer`, `allow_recursion`, …), forwarder IPs,
DHCP subnet/failover parameters, and raw `bind_globals`/`custom_opts` text
blocks injected verbatim into the generated config.

---

## Zone

A **Zone** belongs to exactly one Server. It maps to one DNS zone in
`named.conf` (e.g. `example.com` or `2.168.192.in-addr.arpa`).

### Zone types (stored as a single uppercase char)

| Type char | Meaning |
|-----------|---------|
| `M`       | Master — Sauron is authoritative; it generates the zone file |
| `S`       | Slave — BIND fetches the zone from a master listed in `masters` |
| `F`       | Forward — BIND forwards queries for this zone to `forwarders` |
| `H`       | Hint — root hints zone |

### Forward vs. Reverse

A zone has a boolean `reverse` flag. Reverse zones cover IP→name lookups
(`*.in-addr.arpa`, `*.ip6.arpa`). Sauron can accept a CIDR prefix as the
zone name and converts it to the correct `.arpa` form automatically
(`cidr2arpa`). Reverse zones carry the same host records as forward zones
(Sauron generates both `A`/`AAAA` and `PTR` entries from the same host).

### The zone apex host (type 10)

When a **Master zone** is created, BackEnd automatically inserts a host
record with `domain = '@'` and `type = 10`. In DNS, `@` means the zone's
own name — it is the **zone apex**.

`get_zone` fetches this `@` host internally (via `zonehostid`) and attaches
its `ns`, `mx`, `txt`, and `ip` array fields directly onto the zone
response. This is why zone objects expose `ns`, `mx`, `txt` at the top
level — they are actually stored on the apex host, not on the zone row.

Slave, Forward, and Hint zones do **not** get a type-10 host (they don't
generate zone files). Type 10 is never exposed as a creatable type through
the REST API; it is managed entirely by BackEnd.

### Key zone-level array fields

| Field           | DNS meaning |
|-----------------|-------------|
| `allow_update`  | BIND `allow-update` ACL |
| `allow_query`   | BIND `allow-query` ACL |
| `allow_transfer`| BIND `allow-transfer` ACL |
| `masters`       | Master server IPs (slave zones) |
| `also_notify`   | Extra notify targets |
| `forwarders`    | Forward-zone forwarder IPs |
| `ns`            | Extra NS records |
| `mx`            | Zone-level MX records |
| `txt`           | Zone-level TXT records |
| `zentries`      | Raw zone file entries injected verbatim |
| `zentries_ta`   | Trust-anchor entries |

---

## Host

A **Host** is a DNS record entry inside a zone. The `domain` field is the
label (the part before the zone name); together with the zone's name it
forms the FQDN.

Hosts are the richest entity in the model. A single host record bundles
**all** DNS record types for that label — A, AAAA, MX, NS, CNAME, SRV,
SSHFP, TLSA, TXT, PTR — plus DHCP lease data (MAC, DUID, IAID).

### Host types

The `type` integer controls which array fields are valid for that host
(enforced at the API layer by `_validate_type_fields` in `Host.pm`):

| Type | Name | Valid array fields |
|------|------|--------------------|
| 1    | Regular host | `ips`, `ether`, `hinfo_hw/sw`, `mx_l`, `wks_l`, `sshfp_l`, `srv_l`, `txt_l`, `dhcp_l`, `dhcp_l6`, `printer_l`, `ns_l`, `ds_l`, `tlsa_l`, `subgroups` |
| 2    | NS-only | `ns_l`, `ds_l` |
| 3    | Mail host | `mx_l`, `txt_l` |
| 4    | Alias / CNAME | `alias` (target domain), `cname_txt` |
| 5    | DHCP-only | `printer_l`, `dhcp_l`, `dhcp_l6`, `subgroups` |
| 6    | Static (IP only) | `ips` |
| 7    | Mixed A + MX | `ips`, `mx_l`, `txt_l`, `alias_a` |
| 8    | SRV-only | `srv_l` |
| 9    | DHCPv6 host | `ips`, `ether`, `duid`, `iaid` |
| 11   | SSHFP-only | `sshfp_l` |
| 12   | TLSA-only | `tlsa_l` |
| 13   | TXT-only | `txt_l` |
| 101  | DHCPv6 static | `ips`, `ether`, `duid`, `iaid` |
| 10   | Zone apex (`@`) | `ns`, `mx`, `txt`, `ip` — **internal, not API-creatable** |

Fields not in the type's allowed list are rejected by the API; all types
also accept the universal scalar fields (`comment`, `ttl`, `class`, `grp`,
`expiration`, etc.).

### Key host array fields

| Field      | DNS/DHCP record |
|------------|-----------------|
| `ip` / `ips` | A / AAAA addresses (also drives PTR in reverse zones) |
| `mx_l`     | MX records (priority + name) |
| `ns_l`     | NS records |
| `ds_l`     | DS records (DNSSEC delegation) |
| `sshfp_l`  | SSHFP records |
| `tlsa_l`   | TLSA records (DANE) |
| `srv_l`    | SRV records (priority, weight, port, target) |
| `txt_l`    | TXT records |
| `wks_l`    | WKS records (protocol + services) |
| `dhcp_l`   | DHCPv4 options |
| `dhcp_l6`  | DHCPv6 options |
| `printer_l`| Printer records |
| `alias_a`  | A-record aliases for this host |
| `subgroups`| DHCP subgroup membership |

The wire format for all of these is described in
[[BackEnd-Array-Field-Wire-Format]]; the codec layer that translates them
to/from clean JSON is described in [[Array-Field-Codec-Refactoring]].

---

## How it generates config files

1. The `sauron` CLI iterates every server.
2. For each server it writes `named.conf` (global options + zone stanzas).
3. For each Master zone it writes a zone file by iterating all hosts in that
   zone and emitting the appropriate RR lines from their array fields.
4. DHCP config is generated separately from host `ether`/`duid`/`dhcp_l`
   fields and zone/server DHCP option blocks.

The REST API and legacy CGI both write to the same PostgreSQL tables;
neither generates config files directly — that is always the `sauron` CLI.

## Related

- [[High-Level-Operation]] — export/push/reload lifecycle
- [[User-Server-Zone-Hierarchy]] — permission scoping over this hierarchy
- [[BackEnd-Array-Field-Wire-Format]] — how array fields are stored in BackEnd
- [[Array-Field-Codec-Refactoring]] — how the API translates array fields
