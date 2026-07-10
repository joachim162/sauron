#import "defs.typ": note, warn

= The Generator and the CLI Toolbox <generator>

== The `sauron` CLI

`sauron [options] <servername> [<targetdir>]` turns the database into
daemon configuration. Options:

```
--all           generate everything below
--bind          named.conf (or named.zones) + zone files
--tinydns       DJBDNS (tinydns) data file
--dhcp          dhcpd.conf (IPv4)
--dhcp6         dhcpd6.conf (IPv6)
--printer       printcap
--clean         purge hosts expired > SAURON_REMOVE_EXPIRED_DELAY days
--updateserial  force serial bump on all master zones
--noupdateserial  compute but don't persist new serials
--check         validate output with named-checkconf/named-checkzone/dhcpd -t
--dhcpclass=<n> emit a single DHCP class file
--ignorelocal   skip RFC 1918 subnets
--mail          send pending-change email notifications
--verbose
```

Operationally important properties:

- *Snapshot isolation.* The whole run executes inside one
  `REPEATABLE READ` transaction with
  `db_ignore_begin_and_commit(1)` suppressing nested transactions — the
  generator sees a consistent snapshot even while users keep editing.
  Serial updates are part of the same transaction; if the final commit
  fails (a concurrent conflicting write), files may exist on disk whose
  serial bumps were rolled back — rerun.
- *Atomic file replacement.* Everything is written to
  `*.tmp.<uid>.<pid>` files and renamed into place only after
  successful generation (and, with `--check`, successful validation).
- *Slave mirroring.* If `servers.masterserver` is set, the zone list is
  extended with the master server's M/S/F zones (as slaves), enabling a
  one-row definition of a secondary nameserver.

=== DNS generation (`make_dns`)

For `named.conf` (or `named.zones` when `zones_only`):

+ Header comment, then the server's `bind_globals` text block verbatim.
+ `key {}` and `acl {}` stanzas from the `keys`/`acls` tables
  (TSIG secrets decrypted with `$SAURON_KEY`).
+ The `options {}` block assembled from server columns: paths, version
  string, the `D/Y/N` enum options (only non-default values are
  emitted), check-names, transfer/query sources, then the address match
  lists via `print_cidr_list` — `allow-transfer`, `allow-query`,
  `allow-query-cache`, `allow-recursion`, `allow-notify`, `blackhole`,
  `listen-on`, `listen-on-v6`, `forwarders`.
+ The server's `logging` and `custom_opts` text blocks.
+ One `zone {}` stanza per active zone: `type master|slave|forward|
  hint`, the zone file path (`pzone_path`/`szone_path` + zone name),
  `masters {}` for slaves, `forwarders {}` for forward zones, per-zone
  allow lists, notify settings.

For each *master* zone a zone file is then produced:

+ *Serial decision.* The zone's serial is bumped (via
  `Util::new_serial`, `YYYYMMDDnn` format) only if something changed
  since `serial_date`: the server row, the zone row, any host in the
  zone (`MAX(mdate)` over hosts *and* satellite tables), the recorded
  removal date `rdate`, or — for reverse zones — any `a_entries` row
  inside `reversenet`. `--updateserial` forces it.
+ *Header:* `$TTL`, `$ORIGIN <zone>.`, the SOA assembled from
  server/zone fields (MNAME = `servers.hostname`, RNAME = zone or
  server `hostmaster`, timers with zone-over-server inheritance).
+ *Apex records* from the type-10 host: NS lines (every zone must have
  its `ns` list populated or BIND will refuse the zone), zone MX and
  TXT records (`$DOMAIN` macro expansion in MX targets), server/zone
  contact TXT.
+ *Host records*, iterating all hosts of the zone: A/AAAA from
  `a_entries` (respecting the per-IP `forward` flag), CNAME from alias
  types, MX lists and MX templates, NS + glue for delegations, DS,
  SRV, TXT (including metadata TXT when zone flag 0x01), HINFO
  (suppressible per server), WKS, LOC, RP, SSHFP, TLSA, printer
  records; plus `zentries` raw lines verbatim. Expired hosts
  (`expiration` in the past) are skipped.
+ *Reverse zones* are generated from the *same* host data: every
  `a_entries` row with `reverse = true` whose IP falls inside the
  zone's `reversenet` becomes a PTR record, with the FQDN reassembled
  from the host's forward zone. A dedicated CNAME-hack path implements
  RFC 2317 classless delegation for sub-/24 ranges.
+ With `--check`, `named-checkzone` runs against each produced file and
  a failed zone keeps its old file.

The tinydns branch (`--tinydns`) emits the same data in djbdns
`data` format (Z/&/=/+/\@ lines) — rarely used but a nice proof that
generation is a pure function of the database.

=== DHCP generation (`make_dhcp`, `make_dhcp6`)

`dhcpd.conf` assembly:

+ Global section: the server's `dhcp` / `dhcp_l` option lines verbatim,
  auto-generated `ddns-update-style`, authoritative statements, and —
  when `dhcp_flags` bit 0x02 is set — the `failover peer` block from
  the `df_*` columns (with `split`, `mclt`, ports, delays).
+ Host *classes* from `groups` rows of type 3/103 (`class {}` with
  MAC-based `subclass` matching) — `--dhcpclass` extracts one class
  into its own include file.
+ The *subnet map*: with `dhcp_mode = 1` each `nets` row with
  `subnet = 't'` and DHCP enabled becomes `subnet <net> netmask <mask>
  {}` carrying the net's `dhcp_entries`; with `dhcp_mode = 0` subnets
  are grouped into `shared-network` blocks per VLAN. Dynamic pools come
  from groups of type 2 whose `range` lines land in `pool {}` blocks
  (failover-aware).
+ *Host declarations*: every host with a MAC gets `host <fqdn> {
  hardware ethernet <mac>; fixed-address <ip>; }` plus its group's and
  its own `dhcp_l` lines; `%{domain}`/`%{ether}`/`%{fqdn}`/`%{host}`
  macros in option strings are expanded per host. Hosts of type 9
  (DHCP-only) emit no `fixed-address`.
+ DHCPv6 (`make_dhcp6`) mirrors this per subnet6/host with DUID/IAID
  identity (`host-identifier option dhcp6.client-id`), the `dhcp_l6` /
  `dhcp6` option sets, and its own failover column family.
+ `--check` runs `dhcpd -t` (and `-6 -t`) before renaming files into
  place.

=== Printers, `--clean`, and mail

`make_printcap` renders printer hosts/classes into a printcap file.
`clean_up` (via `--clean`) deletes hosts whose `expiration` passed more
than `$SAURON_REMOVE_EXPIRED_DELAY` days ago (default 30). `--mail`
sends the pending-changes notification list built from history since the
last run.

== The admin CLI toolbox <clitools>

All repo-root scripts share the same bootstrap (`load_config`,
`db_connect`, `set_muser` from the invoking Unix user, `uid/sid = -1`
history entries). The ones you will meet:

#table(
  columns: (auto, 1fr),
  table.header([Tool], [Purpose]),
  [`createtables` / `runsql`], [Create the schema / run arbitrary SQL
    files (used for `dbconvert_*` migrations).],
  [`adduser`, `moduser`, `deluser`, `addgroup`, `delgroup`],
    [User and user-group management, including granting `user_rights`
    rows and superuser status. `deluser` can anonymize instead of
    delete (history rows keep the uid).],
  [`modpat`], [Personal Access Token management for the REST API.],
  [`addzone`], [Create zones from the shell.],
  [`addhosts`, `generatehosts`, `modhosts`, `remove-hosts`,
   `update-hosts`, `addipv6`], [Bulk host operations: add from lists,
    generate numbered ranges, move/rename/delete by pattern, CSV-driven
    updates, batch IPv6 addition.],
  [`import`, `import-zone`, `import-dhcp`, `import-nets`,
   `import-roots`, `import-ethers`, `import-zone-comments`],
    [Importers: whole BIND config trees, single zones (file or AXFR),
    dhcpd.conf, network CSVs, root hints, OUI data.],
  [`export-hosts`, `export-ip-list`, `export-networks`,
   `export-by-group`, `export-vmps`], [Flat-file exports (IP lists,
    /etc/networks, VMPS config).],
  [`check-pending`], [Cron job: detect zones with changes newer than
    their serial and nag by email — the "pending changes" monitor.],
  [`expire-hosts`], [Set expiration on hosts with no DHCP activity
    (using `dhcp_last`/`leases`) — the stale-host reaper.],
  [`update-dhcp-info`], [Parse dhcpd syslog/leases and update
    `hosts.dhcp_date`/`dhcp_last` and the `leases` table — the feedback
    loop from the live DHCP server back into the database.],
  [`dbcheck`], [Consistency checker/fixer for the sentinel-FK schema
    (orphan satellite rows, dangling refs).],
  [`keygen`], [TSIG/DNSSEC key generation into the `keys` table.],
  [`last`, `status`], [Lastlog viewer; system status/maintenance flags
    (e.g. disabling the CGI).],
  [`compare-zones`], [Diff a generated zone against live DNS.],
  [`sauron-browser`-related `config-browser`], [Config for the anonymous
    browser CGI.],
)

These tools demonstrate an important architectural point: *BackEnd was
always the API*. The CGI, the generator, and thirty shell tools all
manipulate the same functions the REST API now exposes over HTTP.
