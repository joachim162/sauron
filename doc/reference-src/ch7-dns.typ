#import "defs.typ": note, warn

= DNS: How It Works, Through Sauron's Eyes <dns>

This chapter gives you the working model of DNS you need to reason about
Sauron confidently. It is organized around what Sauron actually stores and
generates; protocol detail is included where it explains *why* the data
model looks the way it does. (The `doc/rfc/` directory keeps local copies
of the defining RFCs — 1034/1035 for the core, 2181 for clarifications.)

== The namespace: domains, zones, delegation

DNS is a distributed, hierarchical key-value database. Names form a tree
rooted at `.`; a *domain* is a subtree (everything under `example.com`),
while a *zone* is the portion of a subtree actually served together by
one set of authoritative servers. The difference is *delegation*: when
`example.com`'s administrators hand `lab.example.com` to another team,
they place NS records for `lab` in their zone, and `lab.example.com`
becomes a separate zone with its own SOA, serial, and servers.

This is exactly Sauron's model: a `zones` row is a zone (not a domain),
and a *delegation* is a host of type 2 inside the parent zone — a label
carrying NS records (plus optional DS records for DNSSEC) pointing at the
child's nameservers. If those nameservers live *inside* the delegated
subtree (`ns1.lab.example.com`), the parent must also publish their
addresses — *glue records*, Sauron host type 6 — otherwise resolvers
would face a chicken-and-egg lookup.

A name's FQDN is assembled from the host's `domain` label plus the zone
name: host `www` in zone `example.com` is `www.example.com.`. In
zone-file syntax, names not ending in a dot are relative to `$ORIGIN`;
Sauron emits `$ORIGIN <zonename>.` and writes host labels relative — the
classic "forgot the trailing dot" class of bugs is confined to
user-supplied values in fields like MX targets and `cname_txt`
(`Util::add_origin`/`remove_origin` exist precisely for this).

== Resolution: who answers a query

Three roles cooperate to answer `www.example.com A?`:

+ The *stub resolver* (in libc) on a client sends the query to its
  configured *recursive resolver* with the "recursion desired" bit set.
+ The recursive resolver walks the tree: it asks a *root server* (from
  its compiled-in or configured hints — Sauron's `root_servers` table /
  `named.ca`), which refers it to the `.com` servers, which refer it to
  `example.com`'s authoritative servers, which return the answer. Every
  step is cached.
+ The *authoritative server* — what Sauron generates configuration for —
  answers only for its zones, from zone data, with the "authoritative
  answer" bit.

The transport is UDP port 53 with TCP fallback (and TCP mandatory for
zone transfers); messages carry a header (id, flags, response code), a
question section, and answer/authority/additional record sections.

One BIND instance can play both roles, which is why the `servers` table
mixes authoritative options (zones, transfer ACLs) with recursive ones
(`recursion`, `allow-recursion`, `forwarders`, root hints). A Sauron
"server" whose zones are all type M/S with `recursion no` is a pure
authoritative; one with `recursion yes` and forwarders is a campus
resolver. *Forward zones* (type F) splice the two: queries for that zone
are relayed to the listed `forwarders` — typical for corporate split-DNS.

== Caching and TTLs

Every record carries a TTL: how long any cache may reuse it. Sauron's
TTL inheritance is three-level — `a_entries` have no TTL of their own;
the host's `ttl`, else the zone's `ttl`, else the server's `ttl`
(default 86400) applies, emitted once as the zone-file `$TTL` plus
per-record overrides. The config clamps user input to
`$TTL_MIN_SEC`--`$TTL_MAX_SEC` (default 600--86400).

TTLs are why changes are not instant: after the generator runs and BIND
reloads, old answers live on in resolver caches for up to the *previous*
TTL. Negative answers ("no such name") are cached too, governed by the
SOA `minimum` field (RFC 2308) — relevant when someone queries a name
*before* creating it.

== The SOA record and zone serials

Every zone starts with exactly one SOA (Start of Authority) record;
Sauron assembles it from server and zone rows:

#table(
  columns: (auto, auto, 1fr),
  table.header([SOA field], [Sauron source], [Meaning]),
  [MNAME], [`servers.hostname`], [Primary master server name.],
  [RNAME], [`zones.hostmaster` → `servers.hostmaster`], [Responsible
    mailbox, with `@` written as `.` (`hostmaster.example.com.`).],
  [SERIAL], [`zones.serial`], [Version number of the zone — see below.],
  [REFRESH], [`zones.refresh` → server default 43200], [How often
    slaves poll the master for changes.],
  [RETRY], [`zones.retry` → 3600], [Poll retry interval after a failed
    refresh.],
  [EXPIRE], [`zones.expire` → 2419200], [How long slaves keep serving
    the zone with an unreachable master before dropping it.],
  [MINIMUM], [`zones.minimum` → 86400], [Negative-caching TTL.],
)

The serial is the coordination point of the whole system. Slaves transfer
the zone only when the master's serial is *greater* than theirs (compared
with sequence-number arithmetic). Sauron uses the human-readable
`YYYYMMDDnn` convention via `new_serial`: date plus a two-digit revision,
monotonically increasing, at most 100 bumps per day. The generator bumps
a serial only when zone content actually changed (@generator) — this
"data newer than serial" state is precisely Sauron's *pending changes*
concept. Never lower a serial manually; a rollback requires the awkward
wrap-around procedure and desynchronizes every slave.

== Zone replication: masters, slaves, NOTIFY, transfers

A zone of type `M` (master) is generated from the database; a type `S`
(slave) zone tells BIND to fetch it from the servers in the zone's
`masters` list (AXFR — full transfer — or IXFR, incremental). NOTIFY
(RFC 1996) makes propagation prompt: the master pings its slaves when the
serial changes; Sauron's `nnotify` option and `also_notify` list control
this.

Because transfers expose entire zones, they are access-controlled:
`allow-transfer` at server or zone level, expressed as *address match
lists* — the `cidr_entries`-backed AML fields. An AML element can be a
CIDR, a named ACL (the `acls` table → `acl {}` stanzas), a TSIG key
reference, or a negation. *TSIG* (RFC 2845) authenticates DNS messages
with a shared HMAC secret — the `keys` table stores these (RC5-encrypted
via `$SAURON_KEY`) and the generator emits `key {}` stanzas; slaves and
dynamic-update clients present the key. `allow-update` (per zone)
matters for a Sauron site mainly as *something to keep disabled*: Sauron
regenerates zone files, so RFC 2136 dynamic updates would be overwritten
— sites integrate DHCP-to-DNS via Sauron's database instead.

The `masterserver` column automates the secondary side: point a whole
Sauron server row at a master server row, and the generator mirrors all
of the master's zones as slave stanzas.

== Record types, as Sauron stores them

#table(
  columns: (auto, auto, 1fr),
  table.header([RR type], [Sauron storage], [Protocol meaning & rules]),
  [A / AAAA], [`a_entries.ip` (INET) with `forward` flag],
    [Name → IPv4 or IPv6 address. A host may have many; round-robin
    comes free.],
  [PTR], [same `a_entries`, `reverse` flag], [Reverse mapping; generated
    into the matching `.arpa` zone, not stored separately (one source of
    truth for both directions).],
  [CNAME], [host type 4: `alias` (in-zone target id) or `cname_txt`
    (out-of-zone string)], [Alias for *all* record types of a name. A
    CNAME must be the only record at its name and must never appear at a
    zone apex; targets should not themselves be CNAMEs. Sauron enforces
    the structural rules by making the alias a distinct host type with
    no other fields.],
  [MX], [`mx_entries` (pri, mx) or `mx_templates` via `hosts.mx`],
    [Mail routing: lower preference = tried first. Target must be a
    hostname with address records — not an IP, not a CNAME.],
  [NS], [zone apex `ns` list; delegations' `ns_l`], [Authoritative
    servers for a zone (apex) or a child zone (delegation point).],
  [SRV], [`srv_entries` (pri, weight, port, target)], [Service location
    (RFC 2782): `_service._proto.name`. Priority like MX; weight
    load-balances within a priority tier.],
  [TXT], [`txt_entries`; also generated from host metadata with zone
    flag 0x01], [Free text — today mostly SPF/DKIM/verification
    payloads. Long values are split into 255-byte strings
    (`bind_fmt_long_data`).],
  [SOA], [server + zone columns], [Zone header; exactly one per zone.],
  [DS], [`ds_entries` (key_tag, algorithm, digest_type, digest)],
    [DNSSEC delegation-signer: the parent's hash of the child's KSK —
    the one DNSSEC artifact a *parent-side* tool like Sauron must
    carry.],
  [SSHFP], [`sshfp_entries` (algorithm, hashtype, fingerprint)],
    [SSH host-key fingerprints for `VerifyHostKeyDNS`.],
  [TLSA], [`tlsa_entries` (usage, selector, matching_type, data)],
    [DANE: pin TLS certificates in DNS (`_443._tcp.name`).],
  [HINFO], [`hinfo_hw` / `hinfo_sw` (template-validated)], [Host
    hardware/OS info — legacy, suppressible per server
    (`named_flags` 0x04) since it leaks inventory.],
  [WKS], [`wks_entries` / templates], [Ancient well-known-services
    bitmap; suppressible (0x08); kept for compatibility.],
  [LOC / RP], [`hosts.loc`, `rp_mbox`/`rp_txt`], [Geolocation;
    responsible-person, both niche.],
  [Anything else], [`zentries` raw lines], [Escape hatch: arbitrary
    zone-file lines stored verbatim per zone.],
)

== Reverse DNS in detail

Reverse resolution maps addresses to names through ordinary DNS
delegation over special trees: `in-addr.arpa` for IPv4 (bytes reversed:
`10.1.168.192.in-addr.arpa` for 192.168.1.10) and `ip6.arpa` for IPv6
(all 32 nibbles reversed). Sauron accepts a CIDR when creating a reverse
zone and converts it (`cidr2arpa`); the zone row stores the covered
prefix in `reversenet`, which is how the generator selects the
`a_entries` that belong in the zone — *hosts do not belong to reverse
zones; their addresses do*.

Delegation follows octet boundaries, which breaks for subnets smaller
than /24. RFC 2317's workaround — the parent /24 zone holds CNAMEs
pointing each address into a per-range child zone
(`1.0/25.1.168.192.in-addr.arpa`-style) — is implemented in the
generator's "CNAME hack" path for `special range` / `special mask`
delegations. IPv6 has no such problem (nibble boundaries every 4 bits),
but produces enormous names — hence `ip6_to_ip6int` and the MAC/IPv4
embedding auto-assignment policies that keep v6 addresses derivable.

The per-IP `reverse` boolean in `a_entries` handles the common asymmetry
where many names share one address (virtual hosting) but only one PTR
should exist; `zones.noreverse` excludes an entire forward zone from
reverse generation.

== Practical failure modes to keep in mind

- *Serial not bumped / generator not run* — edits invisible; check the
  pending view before debugging BIND.
- *Stale caches* — changes propagate after old TTLs expire; lower TTLs
  *before* planned migrations, not during.
- *Missing glue / broken delegation* — child zone unreachable even
  though its own servers are fine.
- *CNAME constraint violations* — BIND logs and may refuse the zone;
  Sauron's type system prevents most, but `zentries` bypasses all
  checking.
- *Zone rejected at load* — one bad record can take the whole zone out;
  this is exactly what `--check` (named-checkzone before rename) exists
  to prevent.
- *Apex without NS* — a master zone whose apex host lost its `ns` list
  generates an unloadable zone.
