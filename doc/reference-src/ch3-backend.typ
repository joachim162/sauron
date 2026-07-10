#import "defs.typ": note, warn

= The Perl Backend <backend>

All business logic lives in the `Sauron::` module tree. The REST API links
against these modules directly (they are plain Perl, loaded into the same
process), so their calling conventions, global state, and error semantics
are effectively the API's internal ABI.

== Module map and layering

```
┌──────────────────────────────────────────────────────────────┐
│ Entry points: cgi/sauron.cgi · sauron CLI · admin scripts    │
│               · sauron_api (REST)                            │
├──────────────────────────────────────────────────────────────┤
│ Sauron::CGIutil          form engine (legacy CGI only)       │
│ Sauron::CGI::*           menu handlers (legacy CGI only)     │
├──────────────────────────────────────────────────────────────┤
│ Sauron::BackEnd          domain layer: all entity CRUD,      │
│                          permissions, history, sessions      │
├──────────────────────────────────────────────────────────────┤
│ Sauron::Util             validation, IP/CIDR math, passwords │
│ Sauron::UtilZone/UtilDhcp  zone-file / dhcpd.conf parsers    │
│ Sauron::Sauron           config file loading, logmsg         │
├──────────────────────────────────────────────────────────────┤
│ Sauron::DB (= DB-DBI.pm) SQL execution, quoting, txns        │
└──────────────────────────────────────────────────────────────┘
```

Everything is *procedural*: modules export bare functions, and state
(database handle, current user, configuration) lives in package globals.
There are no objects, no exceptions — errors are signaled by return codes
(negative integers or empty strings) and human-readable messages fetched
separately.

== `Sauron::Sauron` — configuration <configfile>

`load_config()` resets \~60 `$main::*` globals to defaults
(`set_defaults`) and then executes the `config` file *as Perl code* in the
`main::` namespace. Consequences:

- Configuration values are ordinary Perl assignments
  (`$DB_DSN = "dbi:Pg:dbname=sauron;host=localhost";`) and can contain
  arbitrary code — the file's permissions are checked (`0022` mask) and
  it must end with a true value.
- Every module reads configuration via `$main::NAME`; there is no config
  object to pass around. The REST API calls `load_config()` once at
  startup, exactly like the CGI.
- A companion `config.key` file, if present, holds a base64 RC5 key
  (`$SAURON_KEY`) used to encrypt TSIG secrets in the `keys` table.

Settings worth knowing beyond the DB credentials: `$SAURON_PRIVILEGE_MODE`
(0 = server rights imply zone rights), `$SAURON_AUTH_MODE` (0 = internal
passwords, 1 = trust the web server's `REMOTE_USER`), `$SAURON_AUTH_PROG`
(external password checker), `$SAURON_USER_TIMEOUT` (CGI session idle
timeout, default 3600 s), `$SAURON_RHF{field}` (required-host-fields
defaults), the `$ALEVEL_*` authorization thresholds, TTL clamps
(`$TTL_MIN_SEC`/`$TTL_MAX_SEC`), the `--check` validator paths
(`$SAURON_NAMED_CHK_PROG`, `$SAURON_ZONE_CHK_PROG`,
`$SAURON_DHCP_CHK_PROG`), and `$SAURON_REMOVE_EXPIRED_DELAY` (days before
`--clean` purges expired hosts). `logmsg(level, msg)` appends to
`$LOG_DIR/sauron.log`.

== `Sauron::DB` — the database layer

A thin, global-state wrapper over DBI. Key facts:

- *One connection per process, held in a package global.*
  `db_connect()` (fatal on failure) or `db_connect2()` (returns status)
  reads `$main::DB_DSN`/`DB_USER`/`DB_PASSWORD`. Once connected, every
  BackEnd call in the process uses it implicitly — nothing takes a handle
  argument. For a persistent API server this means: connect once at
  startup, and remember the connection is shared by everything in the
  worker process.
- *SQL is built by string concatenation.* `db_exec($sql)` runs a
  statement; `db_query($sql, \@result)` fills an array-of-arrays with all
  rows. There are *no placeholders* in the legacy code path — values are
  escaped by hand with `db_encode_str($val)`, which quotes and escapes a
  scalar (returning `''` for undef). Any code you write that touches SQL
  directly must use `db_encode_str` religiously; better, don't write SQL
  at all.
- *List codec.* `db_encode_list_str` / `db_decode_list_str` pack Perl
  lists into a comma-separated encoded string (used by `save_state` for
  the utmp table).
- *Transactions.* `db_begin()`, `db_commit()`, `db_rollback()` — plus the
  quirky `db_ignore_begin_and_commit(1)`, which makes nested
  `db_begin`/`db_commit` calls inside library functions no-ops so a
  caller can hold one big transaction (the generator does exactly this
  with `REPEATABLE READ`). BackEnd's multi-table operations
  (`add_host`, `update_zone`, …) each open their own transaction unless
  suppressed this way.
- *Misc.* `db_lastid()` returns the last `SERIAL` value (via
  `$dbh->last_insert_id`); `db_errormsg()` / `db_lasterrormsg()` fetch
  error text; `db_debug(1)` echoes SQL to the log; `db_insert(table,
  columns, \@rows)` bulk-inserts.

#warn[SQL injection is a real hazard here.][
  Because everything is interpolated strings, a single unescaped value in
  a `WHERE` clause is an injection. BackEnd itself is careful; API
  controllers must never interpolate request input into SQL and should
  treat "call BackEnd, don't write SQL" as a security rule, not merely a
  style rule.
]

== `Sauron::BackEnd` — the domain layer

At 4,551 lines this is the heart of Sauron. It follows a strict
convention: for each entity there is a family

```
get_X($id, \%rec)      →  0 on success, fills %rec (scalars + array fields)
get_X_list(...)        →  arrayref / fills list for menus & pickers
add_X(\%rec)           →  new id  (or negative on failure)
update_X(\%rec)        →  0 / negative; %rec must contain id
delete_X($id)          →  0 / negative; cascades to satellite tables
```

implemented for: `server`, `zone`, `host`, `net`, `vlan`, `group`,
`mx_template`, `wks_template`, `hinfo_template`, `printer_class`, `user`,
`user_group`, `vmps`, `key`, `acl`, `news`, plus lookup helpers
(`get_server_id`, `get_zone_id`, `get_zone_id_by_name`, `get_host_id`,
`get_host_id_by_fqdn`, `get_net_by_cidr`, `get_net_cidr_by_ip`,
`get_group_by_name`, `get_vlan_by_name`, `get_key_by_name`,
`get_acl_by_name`, `get_user_by_email`, `get_user_by_id`, …) and
uniqueness probes (`ip_in_use`, `domain_in_use`, `hostname_in_use`).

Underneath, five generic helpers do the real work against the schema:

- `get_record(table, fields, id, \%rec, joins)` — SELECT one row into a
  hash and `fix_bools` it.
- `add_record(table, \%rec)` / `add_record_sql` — build an INSERT from
  the hash (stamping `cdate`/`cuser` via `add_std_fields`), log the SQL
  to syslog, return the new id.
- `update_record(table, \%rec)` — build an UPDATE from the hash
  (stamping `mdate`/`muser`), keyed on `$rec{id}`.
- `copy_records(...)` — bulk-copy satellite rows (used by `copy_zone`).
- the array-field trio described next.

`set_muser($username)` *must be called before any write* — it sets the
global identity recorded into `cuser`/`muser` and shown in history views.
The CGI calls it right after loading the session; the API sets it per
request from the authenticated user. Forgetting it writes `unknown` into
the audit columns.

=== Array fields: the marker-row wire format <arrayfields>

All one-to-many data flows through three functions, and their in-memory
format is the single most idiosyncratic thing in Sauron. Each array field
on a record hash is an *array of arrays*:

```
$rec->{field} = [
  ['Header', 'Labels'],              # row 0: column headers (UI labels)
  [id, col1, ..., colN, marker],     # data rows
  ...
];
```

- `id` — the satellite row's primary key (`0` for rows not yet in the
  DB).
- `col1..colN` — the data columns, in the satellite table's order.
- `marker` — at index `count` (one past the last data column): `-1` =
  delete this row, `1` = update it, `2` = insert it, `0`/absent = leave
  alone.

The functions:

- `get_array_field(table, count, fields, header, where, \%rec, key)` —
  SELECT satellite rows into that shape (header row first).
- `add_array_field(table, fields, key, \%rec, reffields, refvals)` —
  used by `add_*`: expects data rows *without* a header, inserts each
  row with the parent's `(type, ref)` values appended.
- `update_array_field(table, count, fields, key, \%rec, vals)` — used by
  `update_*`: walks the rows and executes DELETE / UPDATE / INSERT
  according to each marker. Requires the header row.

A parallel pair, `get_aml_field` / `update_aml_field`, handles the BIND
address-match-list fields stored in `cidr_entries`, whose rows have six
data columns (`mode`, `ip`, `acl`, `tkey`, `op`, `comment`, hence
`count = 7`): an AML element can be a CIDR, a reference to a named ACL, a
TSIG key, negated or not.

Example — replacing a host's TXT records the way `update_host` expects:

```perl
$rec{txt_l} = [
  ['Text', 'Comments'],          # header (required for update)
  [7,  '', '',            -1],   # DELETE existing row id=7
  [0,  'v=spf1 mx -all', 'SPF', 2],  # INSERT new row
];
update_host(\%rec);
```

The "replace-all" idiom (mark every existing row `-1`, append fresh rows
as `2`) is what both the legacy CGI's form engine and the API's codec
layer generate. The `count` value differs per field — it is the marker
column index and must match BackEnd's hardcoded expectations (e.g. host
`ip` has `count = 4`: id, ip, reverse, forward, marker; `srv_l` has
`count = 6`). Getting `count` wrong silently corrupts adjacent columns.

#note[API translation layer.][
  The REST API's controllers convert between clean JSON arrays of objects
  and this marker format (`backend_array_to_api`,
  `api_array_to_backend_create/update` in the API's Base helpers), with
  per-resource dispatch tables of headers, builders, and counts. When
  adding a new field to the API, always confirm the column list and count
  against the `get_/add_/update_` calls in `BackEnd.pm` — not against
  documentation.
]

=== Entity-specific behavior worth knowing

- *`get_host`* recursively resolves aliases (a CNAME host pulls in its
  target's data) and joins group, template, and zone names for display.
  It returns everything: scalars, all array fields, plus convenience
  joins. It is *expensive*; list views use `db_query` directly instead.
- *`add_host` / `update_host`* enforce the `UNIQUE(domain, zone)`,
  `UNIQUE(ether, zone)` and DUID constraints only via the database —
  callers must catch failures and translate constraint violations into
  user-facing conflicts (the CGI does string-matching on
  `db_lasterrormsg`; the API returns 409).
- *`delete_zone` / `delete_server`* cascade manually through every
  dependent table (hosts, satellite rows, nets, groups, …) — hundreds of
  lines of explicit DELETEs. They are the reason "call BackEnd" is a data
  integrity rule.
- *`copy_zone(src_server, src_zone, dst_server, dst_zone)`* deep-copies a
  zone with all hosts and satellite rows.
- *`get_zone_list($serverid, $rev_flag, $dummies, $no_expired)`* returns
  `[id, name, type, …]` rows used by menus and the generator.
- *`new_sid()`* allocates a session id (sequence) used to group history
  rows per login session.
- *`get_host_network_settings($serverid, $ip, \%rec)`* finds the net a
  given IP falls into and returns its DHCP-relevant settings — used when
  rendering host forms.

=== IP auto-assignment <autoassign>

`get_free_ip_by_net($serverid, $cidr, $mac, $old_ip, $ip_policy)` is the
one live auto-assignment path (`auto_address` and `next_free_ip` are dead
code — every call site is commented out; don't resurrect them). The
policy comes from the net's `ip_policy` column via
`get_net_ip_policy`:

#table(
  columns: (auto, auto, 1fr),
  table.header([Policy], [Name], [Algorithm]),
  [0], [Lowest free], [Within `range_start`--`range_end`, one SQL query
    finds the first gap after a used block (no Perl-side enumeration).],
  [10], [Highest free], [Mirror image, scanning down from `range_end`.],
  [20], [MAC based (IPv6)], [Embeds the MAC into the low bits of the
    address (EUI-64-style); deterministic per prefix; collision-checked
    against `a_entries`.],
  [30], [IPv4 based (IPv6)], [Embeds an existing IPv4 address into the
    IPv6 address for dual-stack correlation.],
)

Missing prerequisites (no MAC for policy 20, no usable IPv4 for 30)
silently downgrade to policy 0. The return value is an *overloaded
string*: a bare IP on success, or `"S:message"` (subnet-level problem —
no range configured, range exhausted) / `"H:message"` (host-level —
derived address already taken) on failure. Callers test success with
`is_ip($result)`. Note that the function only *suggests* a free address —
nothing is reserved; the real guarantee is the insert-time unique
constraint, so writers must handle "suggested IP got taken" as a
conflict. `get_ip_sugg` builds on this to propose addresses across all
nets sharing the host's VLAN.

=== Permissions, history, sessions (summary)

BackEnd also owns `get_permissions`, `get_user_status`, the history/
lastlog/utmp writers, and the PAT/session token functions — these are
covered with the security model in @security. The logging surfaces are:

#table(
  columns: (auto, auto, 1fr),
  table.header([Function], [Destination], [When]),
  [`write2log`], [syslog (`debug`/`info`)], [Every INSERT built by
    `add_record_sql` — a raw SQL audit trail.],
  [`logmsg`], [`$LOG_DIR/sauron.log`], [Application events (logins,
    warnings) — from `Sauron::Sauron`.],
  [`update_history(uid, sid, type, action, info, ref)`], [`history`
    table], [Every entity mutation. `uid = -1, sid = -1` is the
    convention for CLI/scripted operations.],
  [`update_lastlog(uid, sid, state, ip, host)`], [`lastlog` table],
    [Login (1), logout (2), timeout (3), reconnect (4).],
  [`save_state` / `load_state` / `remove_state`], [`utmp` table],
    [Legacy CGI session persistence, keyed by cookie.],
)

== `Sauron::Util` — validation and IP mathematics

A grab bag the API leans on constantly:

- *Name validation* — `valid_domainname($name)` (and
  `valid_domainname_check` with severity levels controlled by
  `$SAURON_DNSNAME_CHECK_LEVEL`) enforces RFC-conservative hostnames;
  `valid_texthandle`, `valid_hex`, `valid_base64` for other fields.
- *IP/CIDR predicates* — `is_ip`, `is_cidr`, `is_ip6`, `is_ip6_prefix`,
  `is_in_netblock`, `is_cidr_within_cidr`, `cidr4ok`/`cidr6ok`/`cidrok`.
- *Conversions* — `arpa2cidr` / `cidr2arpa` (reverse-zone name ↔
  CIDR, both families), `ip2int`/`int2ip`, `adjust_ip`,
  `normalize_ip6`/`ipv6compress`/`ipv6decompress`, `ip6_to_ip6int`
  (nibble format for `ip6.arpa`), `net_ip_list` (enumerate a block).
- *Zone-file name handling* — `add_origin` / `remove_origin` convert
  between relative labels and FQDNs against a zone origin.
- *Passwords* — `pwd_make($pwd, $mode)` produces `MD5:salt:hash`
  (mode 1) or `CRYPT:salt:hash` (mode 0); `pwd_check($pwd, $stored)`
  verifies both; `pwd_external_check` shells out to
  `$SAURON_AUTH_PROG`. A `LOCKED:` prefix disables an account.
- *DHCP formatting* — `dhcpether` renders the 12-hex `ether` column as
  `aa:bb:cc:dd:ee:ff`; `dhcpduid` likewise for DUIDs; `is_iaid`
  validates IAIDs.
- *Serials* — `new_serial($old)` implements the `YYYYMMDDnn` DNS serial
  convention: today's date with a two-digit counter, incrementing within
  the same day and never going backwards.
- *Process helpers* — `run_command`/`run_command_quiet` (timeouts,
  output capture — used for ping/traceroute and `--check` validators),
  `fatal`/`error` (print-and-die / print-and-return), CSV helpers
  (`print_csv`, `parse_csv`), `utimefmt`, `trim`.

== `Sauron::UtilZone` and `Sauron::UtilDhcp` — importers' parsers

These parse *existing* configurations into Sauron's structures — the
reverse direction from the generator:

- `UtilZone::process_zonefile` reads a BIND zone file (full RFC 1035
  syntax: `$ORIGIN`, `$TTL`, `$INCLUDE`, parenthesized records,
  relative names) into an array of record hashes; `process_zonedns`
  AXFRs a zone via Net::DNS instead. Used by `import` and
  `import-zone`.
- `UtilDhcp::process_dhcpdconf` parses `dhcpd.conf` (subnets, groups,
  hosts, shared-networks) for `import-dhcp`.

They matter to the API only indirectly (imports), but they are the
best executable documentation of what zone-file constructs Sauron
understands.

== Legacy pitfalls checklist

- Booleans are `'t'`/`'f'` strings — always `eq 't'`, never truthiness.
- Call `set_muser` before writes, `db_connect` before anything.
- Errors are negative return codes plus `db_errormsg()`; no exceptions.
  Check *every* return value.
- Array fields: header rows, marker columns, per-field `count` — build
  them exactly, or corrupt data silently.
- All SQL is interpolated strings; `db_encode_str` everything, or
  better, never hand-write SQL.
- Package globals everywhere (`%main::state`, `$main::SAURON_*`,
  the DB handle) — BackEnd is not thread-safe; use process-per-worker
  servers (the API's Mojolicious prefork model fits).
- Every `.pm` ends in `1;`; scripts hardcode `-I` paths (use
  `PERL5LIB` in dev).
- Perl prototypes (`sub get_host($$)`) mean argument counts are checked
  at compile time — pass exactly the right number of arguments.
