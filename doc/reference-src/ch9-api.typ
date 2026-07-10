#import "defs.typ": note, warn

= Building the REST API on This Foundation <api>

This closing chapter condenses the preceding material into the working
rules for the API effort — what to reuse, what to translate, and where
the traps are.

== Ground rules

+ *BackEnd is the contract.* Every read goes through `get_*`, every
  write through `add_*`/`update_*`/`delete_*`. Raw SQL is reserved for
  read-only list endpoints where BackEnd has no suitable function — and
  then only with `db_encode_str` on every value.
+ *One process-global world.* `load_config()` and `db_connect()` once at
  startup; `set_muser($username)` per authenticated request *before* any
  write; remember all state is package globals, so keep the
  process-per-worker model and never share a worker across concurrent
  requests.
+ *Log history like the CGI does.* After every successful mutation:
  `update_history($uid, $sid_or_-1, $type, $action, $info, $ref)` with
  type 1 host / 2 zone / 3 server / 4 net / 5 user / 6 user group.
+ *Authorize from `get_permissions`.* Superuser bypass first, then
  server/zone rights with privilege-mode fall-through, then the masks
  (hostname, delete, template, group), flags, net ranges, ALEVELs, and
  RHF. The legacy `check_perms` semantics in `Sauron/CGI/Utils.pm` are
  the reference implementation.

== Translation tables

*Error semantics.* BackEnd's conventions → HTTP:

#table(
  columns: (auto, 1fr),
  table.header([BackEnd signal], [API response]),
  [`get_*` returns non-zero / lookup helper returns `-1`],
    [404 Not Found (or 400 if the identifier is malformed).],
  [`add_*`/`update_*` negative return + unique-constraint text in
   `db_lasterrormsg()` (`hostname_key`, `ether_key`, `asset_key`,
   `duid_iaid_key`, `nets_key`, …)],
    [409 Conflict naming the conflicting field.],
  [`get_free_ip_by_net` returns `"S:…"`], [422/409 on the *network*
    resource (no range configured vs range exhausted — distinguish
    them).],
  [`get_free_ip_by_net` returns `"H:…"`], [409 on the host/IP
    resource.],
  [Validation failures (`valid_domainname`, TTL clamps, RHF)],
    [400/422 with the field name; enforce *before* calling BackEnd.],
  [Permission denial], [403 (401 only for missing/invalid
    authentication).],
)

*Data shape.* JSON arrays of objects ↔ marker-row arrays
(@arrayfields): strip header/id/marker on the way out; on update, mark
all existing rows `-1` and append new rows as `2` under the correct
per-field `count`. Booleans: `'t'`/`'f'` ↔ JSON true/false at the
boundary, comparing with `eq 't'` internally. Dates: epoch integers ↔
ISO 8601 if the API chooses to prettify (be consistent).

*Identifiers.* The database uses serial ids; URLs prefer stable names
(server name, zone name, host FQDN, netname). The lookup helpers
(`get_server_id`, `get_zone_id`, `get_host_id`, `get_net_by_cidr`, …)
resolve names to ids; do it once per request and 404 early.

== Semantics that must not drift

- *Zone apex handling* — type-10 hosts are created by `add_zone`,
  surfaced as zone-level `ns`/`mx`/`txt` fields, and never exposed as
  hosts.
- *Host-type field validity* — each host type allows a specific set of
  array fields (@database); reject others rather than silently
  dropping.
- *Suggested IPs are not reservations* — after auto-assignment, the
  insert can still fail; treat it as a conflict and retry/report.
- *Pending changes* — expose "zone data newer than serial_date" so the
  frontend can show what the CGI's pending view shows; consider an
  endpoint reporting `servers.lastrun` vs latest `mdate`.
- *Expiration* — expired hosts still exist in the DB but are skipped by
  the generator; list endpoints should surface (not hide) expiration
  state.
- *Cascading deletes* — `delete_zone`/`delete_server` are slow,
  many-statement operations; run them with appropriate timeouts and
  never reimplement the cascade.
- *Generation is out of band* — the API writes the database; producing
  and pushing configs remains the `sauron` CLI's job (cron or an
  explicitly triggered, audited mechanism).

== Suggested reading order for a new contributor

+ This document, chapters 1--2, then the `knowledge/` notes
  `High-Level-Operation` and `Sauron-Domain-Model`.
+ `Sauron/BackEnd.pm`: `get_zone`, `add_zone`, `get_host`,
  `update_host`, `get_array_field`/`update_array_field`,
  `get_permissions` — with chapter 3--4 at hand.
+ `Sauron/CGI/Hosts.pm` for the behavioral spec of host operations.
+ A full read of the generator's `make_dns` once, to internalize how
  the data becomes DNS.
+ Import the `test/` Middle-Earth dataset and step through: edit a host
  in the CGI, watch `history`, run `sauron --all --check`, diff the
  output.
