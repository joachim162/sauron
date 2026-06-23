# BackEnd Array Field Wire Format

How `Sauron::BackEnd` returns, creates, and updates array fields
for Servers, Zones, and Hosts — and how the API controllers translate
between JSON and this format.

## Overview

BackEnd stores one-to-many relationships (DHCP entries, NS records,
SSHFP fingerprints, IP addresses, CIDR ACLs, etc.) in satellite tables
joined to the primary `servers`, `zones`, or `hosts` row. Data flows
through three internal functions:

| Function | Purpose | Key signature |
|---|---|---|
| `get_array_field` | Read satellite rows into a marker-row array | `(table, count, fields, header, where, rec, keyname)` |
| `add_array_field` | Insert new rows during create | `(table, fields, keyname, rec, rfields, vals)` |
| `update_array_field` | Replace-all during update | `(table, count, fields, keyname, rec, vals)` |

A parallel `get_aml_field` / `update_aml_field` pair handles CIDR-based
ACL fields (allow-transfer, listen-on, etc.) with the same marker
convention.

## The Marker-Row Array

Every array field is a Perl array-of-arrays. Row 0 is always a
header (ignored by BackEnd's `update_array_field` but used by
`get_array_field` to name the columns). Each subsequent row is:

```
[id, col1, col2, ..., colN, marker]
```

- `id` — DB primary key (0 for new unsaved rows)
- `col1..colN` — data columns matching the satellite table schema
- `marker` at index `count` — operation flag:
  - `-1` = DELETE this row by id
  - `1`  = UPDATE this row (id must be valid)
  - `2`  = INSERT this row

The `count` value is the index of the marker column (one past the last
data column). For a 2-column field (e.g. DHCP: dhcp + comment),
`count=3` means `[id, dhcp, comment, marker]`.

### Examples

**Simple field (dhcp_l, count=3):**
```perl
# Returned by get_array_field:
$rec->{dhcp_l} = [
  ['DHCP', 'Comments'],            # header (ignored)
  [12, 'option routers 10.0.0.1;', 'wan', 2],   # insert
  [13, 'option ntp 10.0.0.2;',     '', 0],       # existing (marker=0 means no-op)
];
```

**AML field (allow_transfer, count=7):**
```perl
$rec->{allow_transfer} = [
  ['aml', 0],                                  # header
  [5, 0, '10.0.0.0/8', -1, -1, 0, '', 2, ...], # cols: id, mode, ip, acl, tkey, op, comment, marker
];
```
AML rows have 6 data columns (mode, ip, acl, tkey, op, comment) plus
the id at [0] and marker at [7]. There are also join columns after the
marker (type, ref) from the SQL query; these are ignored in the row
format.

## Return Path (`get_array_field`)

BackEnd calls `get_array_field` for each array field. This runs an SQL
query against the satellite table and builds the marker-row array. The
controller then calls `strip_marker_format` (via
`backend_array_to_api`) to convert it to a clean JSON array of objects.

```perl
# BackEnd (get_array_field returning):
$rec->{txt_l} = [
  ['Text', 'Comments'],                        # from sql column names
  [7, 'v=spf1 mx -all', 'SPF', 2],            # id=7, txt, comment, marker
  [8, 'some text', '', 2],
];

# Controller strips to API:
$response->{txt_l} = [
  { txt => 'v=spf1 mx -all', comment => 'SPF' },
  { txt => 'some text',      comment => '' },
];
```

## Create Path (`add_array_field`)

Used by `add_server`, `add_zone`, `add_host`. Expects data rows
**without a header**. Each row must have at least `N+1` elements where
N is the number of INSERT columns fed from the rec key.

```perl
# Host.pm passes:
$rec->{txt_l} = [
  [0, 'v=spf1 mx -all', 'SPF', 2],     # no header!
];

# BackEnd add_server for dhcp_l:
add_array_field('dhcp_entries','dhcp,comment','dhcp_l',$rec,'type,ref',"7,$id");
# Inserts: INSERT INTO dhcp_entries (dhcp,comment,type,ref)
#          VALUES('v=spf1 mx -all','SPF',7,42)
```

## Update Path (`update_array_field`)

Used by `update_server`, `update_zone`, `update_host`. Implements
"replace-all" semantics: existing rows are marked for deletion
(marker=-1), new rows are appended (marker=2). The header row is
required at index 0.

```perl
# Controller builds:
$rec->{txt_l} = [
  ['Text', 'Comments'],                        # header
  [7, '', '', '', -1],                          # DELETE id=7
  [8, '', '', '', -1],                          # DELETE id=8
  [0, 'new txt', 'comment', 2],                # INSERT
];

# BackEnd processes in order:
# 1. DELETE FROM txt_entries WHERE id=7
# 2. DELETE FROM txt_entries WHERE id=8
# 3. INSERT INTO txt_entries (txt,comment,type,ref) VALUES('new txt','comment',2,42)
```

The controller idiom is:

```perl
my $data = build_array_field($json_data, $field, $backend_headers, $builders);
my @rows = ($data->[0]);                    # keep header
mark_existing_for_deletion(\@rows, $existing, $count);  # mark old rows -1
push @rows, @{$data}[1..$#$data];           # append new rows
$rec{$field} = \@rows;
```

## Per-Resource Dispatch Tables

Each resource defines which fields are arrays, their column names,
builders, and count values:

| Table | @ARRAY_FIELDS | Field type categories |
|---|---|---|
| Server | allow_transfer, allow_query, allow_recursion, ..., forwarders, dhcp_l, dhcp, txt, logging, custom_opts, bind_globals, dhcp6_l, dhcp6 | AML (count=7), simple (count=3) |
| Zone | allow_update, allow_query, allow_transfer, masters, also_notify, forwarders, dhcp, ns, mx, txt, zentries_ta, zentries | AML (count=7), IP (count=3), forwarder (count=4), MX (count=4), simple (count=3) |
| Host | ns_l, ds_l, wks_l, mx_l, dhcp_l, dhcp_l6, printer_l, srv_l, sshfp_l, tlsa_l, txt_l, alias_a, subgroups | Variable count per field (2–6) |

The dispatch tables are declared in each controller's `%BACKEND_HEADERS`,
`%HEADERS`, `%BUILDERS`, and `%UPDATE_COUNT`.

## count Per Field

The `count` parameter is the marker column index, equal to the number of
data columns + 1 (for id). Always check `BackEnd.pm` to confirm — each
satellite table/schema pair has its own count.

| Server | $count | Table | Columns (after id) |
|---|---|---|---|
| AML fields | 7 | cidr_entries | mode, ip, acl, tkey, op, comment |
| forwarders | 3 | cidr_entries | ip, comment |
| dhcp_l / dhcp | 3 | dhcp_entries | dhcp, comment |
| txt / logging / custom_opts / bind_globals | 3 | txt_entries | txt, comment |
| dhcp6_l / dhcp6 | 3 | dhcp_entries | dhcp, comment |

| Zone | $count | Table | Columns (after id) |
|---|---|---|---|
| AML fields | 7 | cidr_entries | mode, ip, acl, tkey, op, comment |
| masters / also_notify | 3 | cidr_entries | ip, comment |
| forwarders | 4 | cidr_entries | ip, port, comment |
| dhcp | 3 | dhcp_entries | dhcp, comment |
| ns | 3 | ns_entries | ns, comment |
| mx | 4 | mx_entries | pri, mx, comment |
| txt / zentries | 3 | txt_entries | txt, comment |
| zentries_ta | 2 | txt_entries | txt |

| Host | $count | Table | Columns (after id) |
|---|---|---|---|
| ip | 4 | a_entries | ip, reverse, forward |
| ns_l | 3 | ns_entries | ns, comment |
| ds_l | 6 | ds_entries | key_tag, algorithm, digest_type, digest, comment |
| wks_l | 4 | wks_entries | proto, services, comment |
| mx_l | 4 | mx_entries | pri, mx, comment |
| dhcp_l / dhcp_l6 | 3 | dhcp_entries | dhcp, comment |
| printer_l | 3 | printer_entries | printer, comment |
| srv_l | 6 | srv_entries | pri, weight, port, target, comment |
| sshfp_l | 5 | sshfp_entries | algorithm, hashtype, fingerprint, comment |
| tlsa_l | 6 | tlsa_entries | usage, selector, matching_type, association_data, comment |
| txt_l | 3 | txt_entries | txt, comment |
| alias_a | 2 | arec_entries | arec |
| subgroups | 2 | group_entries | grp |

## Architecture Summary

```
JSON API (array of objects)
  ↗  backend_array_to_api        API controllers via SauronAPI::Controller::Base
  ↘  api_array_to_backend_create / api_array_to_backend_update
    ──────────────────────────────────────────────────────────────
Marker-row arrays with header / id / marker columns
  ↗  get_array_field              Sauron::BackEnd
  ↘  add_array_field / update_array_field
    ──────────────────────────────────────────────────────────────
Satellite tables (dhcp_entries, txt_entries, cidr_entries, ...)
```

## See Also

- [[Update-Host-Marker-Format]] — earlier detailed notes on host updates
- [[Sauron-Core-Integration]] — how the API loads and calls BackEnd
