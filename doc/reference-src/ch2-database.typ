#import "defs.typ": note, warn

= The Database <database>

PostgreSQL is Sauron's single source of truth. The schema lives in `sql/`,
one file per table, created by the `createtables` utility. This chapter
covers the schema conventions, every table group, and the columns you will
actually touch from the API.

== Schema conventions

*Table inheritance.* Most entity tables inherit from the virtual table
`common_fields`:

```sql
CREATE TABLE common_fields (
    cdate      INT4,                          -- creation date
    cuser      CHAR(321) DEFAULT 'unknown',   -- creating user
    mdate      INT4,                          -- modification date
    muser      CHAR(321) DEFAULT 'unknown',   -- last changed by
    expiration INT4                           -- expiration date
);
```

Every server, zone, host, net, vlan, group, and user row therefore carries
creation/modification stamps and an optional expiration. `BackEnd`
maintains these automatically (`add_std_fields`), using the identity set
via `set_muser()`. The generator compares these `mdate` values against
zone `serial_date` to decide which zones need a new serial.

*Epoch integers, not timestamps.* All dates are `INT4` Unix epoch
seconds. `0` or `NULL` generally means "not set"; expiration `<= 0` means
"never expires".

*Sentinel foreign keys.* References use plain `INT4` columns with `-1`
(sometimes `0`) meaning "no reference" — there are *no* SQL foreign-key
constraints. Referential integrity is enforced (imperfectly) by
application code; the `dbcheck` utility exists to find and fix orphans.

*Booleans come back as `'t'`/`'f'`.* PostgreSQL boolean columns are
returned by DBD::Pg as the strings `t` and `f`. `BackEnd::fix_bools`
normalizes record hashes to these one-letter forms. Perl treats *both* as
truthy, so every boolean test must compare explicitly:
`$rec{superuser} eq 't'`. This is one of the most common bug sources when
wrapping BackEnd.

*The satellite-table pattern.* One-to-many data (a host's IP addresses,
MX records, DHCP option lines…) is never stored inline; each kind lives
in its own small "satellite" table with a *polymorphic reference*: a
`type` column saying which parent table the row belongs to and a `ref`
column holding the parent id. For example `dhcp_entries.type` uses 1 =
global/server DHCP, 2 = zone (unused), 3 = group, 4 = host, 5 = net,
6 = vlan, 7 = server dhcp_l. The exact type codes differ per satellite
table and are encoded in `BackEnd`'s calls — treat them as opaque and go
through `BackEnd` (see @arrayfields).

== Core entity tables

=== `servers` — managed BIND/dhcpd instances

One row per managed daemon pair; the top of the hierarchy. Groups of
columns:

#table(
  columns: (auto, 1fr),
  table.header([Column group], [Purpose]),
  [`name`, `comment`], [Unique server name; free-text description.],
  [`lastrun`], [Epoch of the last generator run for this server.],
  [`zones_only`, `no_roots`, `masterserver`, `named_flags`],
    [Generation behavior: emit only `named.zones` instead of a full
    `named.conf`; skip the root-hints zone; dynamically mirror another
    server's zones as slave zones (`masterserver` points at the master
    server row); bit flags (0x01 access control from master, 0x02 include
    master's slave zones, 0x04 suppress HINFO, 0x08 suppress WKS).],
  [`directory`, `pid_file`, `dump_file`, `named_xfer`, `stats_file`,
   `memstats_file`, `named_ca`, `pzone_path`, `szone_path`],
    [Paths emitted into `named.conf`; `pzone_path`/`szone_path` are the
    relative directories for master/slave zone files.],
  [`query_src_ip/_port`, `listen_on_port`, `transfer_source`, plus `_v6`
   variants], [Query source, listen ports and transfer source addresses.],
  [`forward`, `checknames_m/s/r`, `nnotify`, `recursion`,
   `authnxdomain`, `dialup`, `multiple_cnames`, `rfc2308_type1`],
    [Single-character enums for BIND boolean options: `D` = default (omit
    from output), `Y`/`N` = yes/no; check-names uses `D/W/F/I`
    (default/warn/fail/ignore).],
  [`ttl`, `refresh`, `retry`, `expire`, `minimum`],
    [Default SOA timers inherited by zones that leave theirs `NULL`.],
  [`dhcp_mode`, `dhcp_flags`, `dhcp_flags6`, `df_*`, `df_*6`],
    [DHCP generation: `dhcp_mode` 0 = build the subnet map from VLANs
    (shared-networks), 1 = from nets; flags 0x01 = auto-generate domain
    names, 0x02 = enable failover; `df_*` are the failover parameters
    (port, max-response-delay, max-unacked-updates, mclt, split,
    load-balance-max-seconds), duplicated for DHCPv6.],
  [`hostname`, `hostaddr`, `hostmaster`],
    [The server's own FQDN and IP (used as SOA MNAME and for slave
    `masters` lists) and the default SOA RNAME for its zones.],
)

Array fields attached via satellite tables: the server-level BIND address
match lists (`allow_transfer`, `allow_query`, `allow_query_cache`,
`allow_recursion`, `allow_notify`, `blackhole`, `listen_on`,
`listen_on_v6`, `forwarders` — in `cidr_entries`), global DHCP option
blocks (`dhcp`, `dhcp_l`, `dhcp6` — in `dhcp_entries`), and raw text
blocks injected verbatim into generated files (`bind_globals`, `logging`,
`custom_opts`, `txt` — in `txt_entries`).

=== `zones` — DNS zones

#table(
  columns: (auto, 1fr),
  table.header([Column], [Purpose]),
  [`server`], [Owning server id (`servers.id`). `UNIQUE(name, server)`.],
  [`name`], [Zone name *without* trailing dot (`example.com`,
    `2.168.192.in-addr.arpa`).],
  [`type`], [Single char: `M`aster, `S`lave, `F`orward, `H`int.],
  [`active`], [Only active zones are emitted into `named.conf`.],
  [`dummy`], [Dummy zones exist for organizational purposes and are
    excluded from generation.],
  [`reverse`, `reversenet`, `noreverse`], [`reverse` marks
    `*.arpa` zones; `reversenet` caches the CIDR the reverse zone covers
    (used to find which A records belong in it); `noreverse` excludes a
    forward zone's addresses from reverse map generation.],
  [`serial`, `serial_date`, `rdate`], [Zone serial (string, typically
    `YYYYMMDDnn`), when it was last bumped, and the last host *removal*
    date (removals must also trigger serial bumps).],
  [`refresh`, `retry`, `expire`, `minimum`, `ttl`], [SOA timers; `NULL`
    inherits the server default.],
  [`hostmaster`], [SOA RNAME override; falls back to the server's.],
  [`forward`, `nnotify`, `chknames`, `class`], [Per-zone BIND options,
    same enum conventions as the server.],
  [`flags`], [Bit 0x01: generate TXT records from the host `huser`,
    `dept`, `location`, `info` fields.],
  [`transfer_source`, `transfer_source_v6`], [Per-zone transfer source.],
)

Zone array fields (satellite tables): `allow_update`, `allow_query`,
`allow_transfer` (address match lists), `masters` and `also_notify` (IP
lists for slave zones and extra NOTIFY targets), `forwarders` (with
optional port), `dhcp` (zone-scoped DHCP options), `ns`, `mx`, `txt`
(apex records — see below), and `zentries` / `zentries_ta` (raw zone-file
lines injected verbatim).

#note[The zone apex is a hidden host.][
  When a master zone is created, `BackEnd::add_zone` automatically inserts
  a host row with `domain = '@'` and `type = 10`. In zone-file syntax `@`
  means "the zone name itself" — the apex. `get_zone` internally looks up
  this apex host and grafts its `ns`, `mx`, `txt`, and `ip` array fields
  onto the zone record it returns, which is why zone objects appear to
  carry NS/MX/TXT lists. Slave/forward/hint zones get no apex host (they
  have no generated zone file), and type 10 must never be exposed as a
  user-creatable host type.
]

=== `hosts` — everything with a name

One row per DNS label per zone (`UNIQUE(domain, zone)`), but "host" is
broader than "machine": the `type` column determines what the row
represents and which fields are meaningful.

#table(
  columns: (auto, auto, 1fr),
  table.header([Type], [Meaning], [Key fields / generated records]),
  [0], [Misc], [Reserved.],
  [1], [Host], [The workhorse: A/AAAA (`a_entries`), PTR, MAC
    (`ether`), HINFO, MX list, NS list, TXT, SRV, SSHFP, TLSA, WKS,
    printer entries, DHCP options, group membership.],
  [2], [Delegation], [NS records (+ DS records) delegating a child zone.],
  [3], [Plain MX], [MX records only — a mail domain with no address.],
  [4], [Alias (CNAME)], [`alias` points at the target host row;
    `cname_txt` holds an out-of-zone target string.],
  [5], [Printer], [Printer entries for printcap generation.],
  [6], [Glue record], [A record for a nameserver inside a delegated
    child zone.],
  [7], [Alias (A record)], [Additional A records pointing at another
    host's addresses (`arec_entries` on the *target*).],
  [8], [SRV entry], [SRV records only.],
  [9], [DHCP only], [MAC reservation with no DNS records.],
  [10], [Zone apex], [Internal, one per master zone (see above).],
  [11], [SSHFP entry], [SSHFP records only.],
  [12], [TLSA entry], [TLSA records only.],
  [13], [TXT entry], [TXT records only.],
  [101], [Host reservation], [Pre-registered DHCPv6 host (DUID/IAID).],
)

Scalar columns shared by most types:

- *DNS basics* — `domain`, `ttl` (NULL = zone default), `class`
  (always `IN` in practice), `router` (>0 marks router priority),
  `hinfo_hw`/`hinfo_sw` (HINFO), `loc` (LOC), `rp_mbox`/`rp_txt` (RP),
  `wks`/`mx` (pointers to WKS/MX *templates*, see below).
- *DHCP identity* — `ether` (12 hex chars, no separators), `ether_alias`
  (borrow another host's MAC), `duid`/`iaid` (DHCPv6 identity;
  `UNIQUE(zone, duid, COALESCE(iaid,0))`), `dhcp_date`/`dhcp_last`
  (lease activity timestamps maintained by `update-dhcp-info`).
- *Administrative metadata* — `huser`, `email`, `dept`, `location`,
  `info` (also emitted as TXT if zone flag 0x01), `model`, `serial`,
  `misc`, `asset_id` (unique per zone), `comment`, `grp` (host group).

Host array fields and their satellite tables (columns beyond `id` and the
parent ref):

#table(
  columns: (auto, auto, 1fr),
  table.header([Field], [Table], [Data columns]),
  [`ip`], [`a_entries`], [`ip INET`, `reverse BOOL` (emit PTR),
    `forward BOOL` (emit A/AAAA), `comment`],
  [`ns_l`], [`ns_entries`], [`ns`, `comment`],
  [`ds_l`], [`ds_entries`], [`key_tag`, `algorithm`, `digest_type`,
    `digest`, `comment`],
  [`mx_l`], [`mx_entries`], [`pri`, `mx`, `comment`],
  [`srv_l`], [`srv_entries`], [`pri`, `weight`, `port`, `target`,
    `comment`],
  [`txt_l`], [`txt_entries`], [`txt`, `comment`],
  [`sshfp_l`], [`sshfp_entries`], [`algorithm`, `hashtype`,
    `fingerprint`, `comment`],
  [`tlsa_l`], [`tlsa_entries`], [`usage`, `selector`, `matching_type`,
    `association_data`, `comment`],
  [`wks_l`], [`wks_entries`], [`proto`, `services`, `comment`],
  [`dhcp_l`, `dhcp_l6`], [`dhcp_entries`], [`dhcp` (a literal dhcpd.conf
    line), `comment`],
  [`printer_l`], [`printer_entries`], [`printer`, `comment`],
  [`alias_a`], [`arec_entries`], [`arec` (host id of an A-alias pointing
    here)],
  [`subgroups`], [`group_entries`], [`grp` (extra DHCP group
    memberships)],
)

=== `nets` and `vlans` — the IP topology

`nets` rows describe networks and subnets (`net CIDR NOT NULL`,
`UNIQUE(net, server)`):

- `netname` (short URL-safe handle) vs `name` (human description).
- `subnet` — true for real subnets (these become `subnet {}` blocks in
  `dhcpd.conf`); false for aggregate/parent networks.
- `dummy` — virtual subnets used to group hosts *inside* a real subnet;
  never generate DHCP configuration.
- `vlan` — pointer into `vlans`, grouping subnets into layer-2 domains;
  with `servers.dhcp_mode = 0` the generator emits one DHCP
  `shared-network` per VLAN.
- `range_start` / `range_end` — the *IP auto-assignment range* used by
  `get_free_ip_by_net` (@autoassign). Distinct from the CIDR itself; a
  net without a range cannot auto-assign.
- `no_dhcp` — exclude from DHCP generation; `alevel` — authorization
  level required to see/use the net; `type` bit 0x01 hides it from the
  public browser; `ip_policy` (added by migration) selects the
  auto-assignment strategy.

`vlans` is a simple name + `vlanno` + description table. The related
`vmps` table stores VLAN Management Policy Server domains for the
`export-vmps` tool, and `unallocated_subnets` supports the "free blocks"
views.

=== `groups` — host groups (not user groups!)

`groups` rows are *host* groups scoped to a server: hosts point at them
via `hosts.grp` (plus extra memberships via `group_entries`). A group
bundles DHCP/BOOTP/printer settings shared by its members. `type`
distinguishes: 1 = normal group, 2 = dynamic address pool (its
`dhcp_entries` describe `range` statements), 3 = DHCP class subclassed by
MAC, 103 = custom DHCP class. Do not confuse with `user_groups`
(@security).

=== Templates: `mx_templates`, `wks_templates`, `hinfo_templates`, `printer_classes`

Reusable record bundles referenced from hosts:

- *MX templates* — a named list of `(pri, mx)` pairs in `mx_entries`;
  `hosts.mx` points at one, so hundreds of hosts can share "standard
  mail routing" and be retargeted centrally.
- *WKS templates* — legacy Well-Known-Services bitmaps, same pattern via
  `hosts.wks`.
- *HINFO templates* — the `hinfo_hw`/`hinfo_sw` free-text fields are
  validated against `hinfo_templates` rows (type 1 = hardware, 2 =
  software) so inventory values stay canonical.
- *Printer classes* — named `printer_entries` bundles for printcap
  generation.

== Users, permissions, and sessions

#table(
  columns: (auto, 1fr),
  table.header([Table], [Purpose]),
  [`users`], [UI/API accounts: `username` (unique), `password` (hashed,
    see @security), `superuser BOOL`, `gid` (default user group),
    `server`/`zone` (default view for the CGI), `email`, `last`,
    `last_from` (login tracking), `flags` (0x01 email notifications),
    plus `common_fields` (so accounts can expire).],
  [`user_groups`], [Named groups of users; purely an indirection target
    for rights.],
  [`user_rights`], [The whole authorization model: `(type, ref)`
    identifies the *subject* (1 = a user group, 2 = a user), `rtype`
    the *kind* of right, `rref` the object id, `rule` a mode string or
    regex. Covered fully in @security.],
  [`personal_access_tokens`], [API bearer tokens (`sau_sk_…`), stored as
    salted hashes; managed by `BackEnd` `create_pat`/`verify_pat`/
    `revoke_pat` and the `modpat` CLI.],
  [`bff_sessions`], [Cookie sessions for the new frontend
    (`create_session`/`verify_session`/`delete_session`).],
)

== Operational and audit tables

#table(
  columns: (auto, 1fr),
  table.header([Table], [Purpose]),
  [`history`], [The audit trail. Every mutation writes `(sid, uid, date,
    type, ref, action, info)` where `type` is 1 = host, 2 = zone, 3 =
    server, 4 = net, 5 = user, 6 = user group. Written by
    `BackEnd::update_history`; queried by the CGI's History views.],
  [`lastlog`], [Login/logout/timeout/reconnect events per user
    (`state` 1--4), with IP and hostname.],
  [`utmp`], [*Live CGI sessions.* Keyed by the 32-hex session cookie;
    stores uid, sid, auth flag, superuser flag, current server/zone
    selection, search state, login/last-activity times. The CGI's
    `save_state`/`load_state` serialize the whole UI state here;
    `fix_utmp` reaps expired rows.],
  [`leases`], [DHCP lease observations imported from dhcpd logs/leases
    by `update-dhcp-info`: ip, mac, duid, start/end, optional link to a
    host row. Powers "last seen" data and `expire-hosts`.],
  [`news`], [Message-of-the-day entries shown at login.],
  [`keys`], [TSIG/DNSSEC key material per server (name, algorithm,
    secret — RC5-encrypted with `$SAURON_KEY` when configured).],
  [`acls`], [Named BIND ACLs per server; their member address-match
    lists live in `cidr_entries`.],
  [`root_servers`], [Root hint records (one row per NS/A record of
    `named.ca`) per server.],
  [`ether_info`], [OUI manufacturer prefixes (from `import-ethers`) for
    display next to MACs.],
  [`settings`], [Global key/value pairs; notably the schema version
    checked by `sauron_db_version()` vs `get_db_version()`, and the
    `cgi_disabled` maintenance flag.],
)

#warn[Schema versioning is manual.][
  `BackEnd::sauron_db_version()` returns the code's expected version
  string ("1.8" family); `get_db_version()` reads the `settings` table.
  Every entry point (CGI, generator, API) refuses to run on a mismatch.
  Upgrades apply `sql/dbconvert_X.Y_to_X.Z` scripts by hand (`runsql`).
  Any new API-supporting tables (PATs, sessions) follow the same pattern.
]

== Entity-relationship overview

```
                 ┌────────────┐
                 │  servers   │
                 └─────┬──────┘
      ┌─────────┬──────┼────────┬───────────┬──────────┐
      ▼         ▼      ▼        ▼           ▼          ▼
 ┌────────┐ ┌──────┐ ┌──────┐ ┌────────┐ ┌───────┐ ┌────────────┐
 │ zones  │ │ nets │ │vlans │ │ groups │ │ keys/ │ │root_servers│
 └───┬────┘ └──┬───┘ └──────┘ └───┬────┘ │ acls  │ └────────────┘
     ▼         │ vlan──────▲      │      └───────┘
 ┌────────┐    └───────────┘      │
 │ hosts  │◄── grp ───────────────┘
 └───┬────┘
     │  1:N satellite tables (type,ref polymorphic refs)
     ▼
 a_entries · mx_entries · ns_entries · txt_entries · srv_entries
 sshfp_entries · tlsa_entries · ds_entries · wks_entries
 dhcp_entries · printer_entries · arec_entries · group_entries
 cidr_entries (address-match lists, also used by servers/zones/acls)
```
