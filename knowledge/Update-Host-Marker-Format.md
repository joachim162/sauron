# Update Host: BackEnd Marker Format

**Note:** This file covers the Host update path only. For a general
overview covering all three resources (Server, Zone, Host) across
create/read/update operations, see [[BackEnd-Array-Field-Wire-Format]].

This document explains how the Host API's `update_host` controller works,
focusing on the data structure expected by `Sauron::BackEnd::update_host`.

## Data Flow Overview

1. Controller builds `%rec` hash with scalar and array fields
2. `BackEnd::update_record` updates the `hosts` table (scalars only)
3. `BackEnd::update_array_field` processes each satellite table (array fields)

## `%rec` Hash Structure

The hash has two kinds of keys:

### Scalar Keys

Updated directly in the `hosts` table by `update_record`:

```perl
my %rec = (
  id     => $host_id,
  zone   => $host_data{zone},
  type   => $host_data{type},
  domain => $host_data{domain},
);
# Plus any scalar fields from API input:
# ttl, class, grp, alias, cname_txt, hinfo_hw, hinfo_sw, router,
# ether, ether_alias, info, location, dept, huser, email, model,
# serial, misc, asset_id, comment, duid, iaid, flags, expiration,
# prn, wks, mx, rp_mbox, rp_txt
```

`update_record` generates: `UPDATE hosts SET col1=val1, col2=val2 WHERE id=$id`

**Critical:** It skips any value that is an `ARRAY` ref (line 598 of BackEnd.pm).
This is why array fields must be arrays, not hashes — hashes would get stringified
as `HASH(0x...)` and cause SQL errors.

### Array Keys

Updated in separate satellite tables by `update_array_field`:

```perl
$rec{sshfp_l} = [...];  # Processed by update_array_field("sshfp_entries", 5, ...)
$rec{ns_l}    = [...];  # Processed by update_array_field("ns_entries", 3, ...)
$rec{mx_l}    = [...];  # etc.
$rec{ip}      = [...];  # Processed by update_array_field("a_entries", 4, ...)
```

## `$count` Values

The `$UPDATE_COUNT` hash in the controller maps each field to its `$count` parameter
used by BackEnd. This value must match what BackEnd's `update_host` passes to
`update_array_field`:

| Field       | `$count` | Table           | Fields (from BackEnd)                                          | `$vals`  |
|-------------|----------|-----------------|---------------------------------------------------------------|----------|
| `ip`        | 4        | `a_entries`     | `ip,reverse,forward,host`                                     | `$id`    |
| `ns_l`      | 3        | `ns_entries`    | `ns,comment,type,ref`                                         | `2,$id`  |
| `ds_l`      | 6        | `ds_entries`    | `key_tag,algorithm,digest_type,digest,comment,type,ref`       | `2,$id`  |
| `wks_l`     | 4        | `wks_entries`   | `proto,services,comment,type,ref`                             | `1,$id`  |
| `mx_l`      | 4        | `mx_entries`    | `pri,mx,comment,type,ref`                                     | `2,$id`  |
| `dhcp_l`    | 3        | `dhcp_entries`  | `dhcp,comment,type,ref`                                       | `3,$id`  |
| `dhcp_l6`   | 3        | `dhcp_entries`  | `dhcp,comment,type,ref`                                       | `13,$id` |
| `printer_l` | 3        | `printer_entries`| `printer,comment,type,ref`                                    | `2,$id`  |
| `srv_l`     | 6        | `srv_entries`   | `pri,weight,port,target,comment,type,ref`                     | `1,$id`  |
| `sshfp_l`   | 5        | `sshfp_entries` | `algorithm,hashtype,fingerprint,comment,type,ref`             | `1,$id`  |
| `tlsa_l`    | 6        | `tlsa_entries`  | `usage,selector,matching_type,association_data,comment,type,ref` | `1,$id`  |
| `txt_l`     | 3        | `txt_entries`   | `txt,comment,type,ref`                                        | `2,$id`  |
| `alias_a`   | 2        | `arec_entries`  | `arec,host`                                                   | `$id`    |
| `subgroups` | 2        | `group_entries` | `grp,host`                                                    | `$id`    |

## Marker Format

Each array field is an array of rows. Row at index 0 is the header (ignored).
Rows at index 1+ are data rows.

Each data row has the format:
```
[id, field1, field2, ..., fieldN, marker]
```

Where `marker` is at index `$count`:

### marker = -1 (DELETE)

```perl
my @del = ($db_id, ('') x ($count - 1), -1);
# For sshfp_l ($count=5): [$id, '', '', '', '', -1]
```

BackEnd reads only `[0]` for the DB row id and `[$count]` for the marker:
```perl
$str="DELETE FROM sshfp_entries WHERE id=$id";
```

### marker = 2 (ADD)

```perl
my @add = (0, $algorithm, $hashtype, $fingerprint, $comment, 2);
# For sshfp_l: [0, 1, 1, 'abc123', '', 2]
```

BackEnd reads indices 1 through `$count-1`:
```perl
for $j(1..($count-1)) {  # j=1,2,3,4 for sshfp
  $str.=db_encode_str($$list[$i][$j]);  # builds VALUES('alg','ht','fp','comment')
}
$str.=",$vals)";  # appends ",1,12" for type=1, ref=host_id
```

Result: `INSERT INTO sshfp_entries (algorithm,hashtype,fingerprint,comment,type,ref) VALUES('1','1','abc123','',1,12)`

### marker = 1 (UPDATE)

```perl
my @upd = ($db_id, $alg, $ht, $fp, $comment, 1);
```

BackEnd builds:
```perl
for $j(1..($count-1)) {
  $str.="$f[$j-1]=" . db_encode_str($$list[$i][$j]);
}
$str.=" WHERE id=$id";
```

## Replace-All Semantics

The controller implements "replace-all" for array fields: delete all existing
records, then add all new ones from the API input.

```perl
# From Host.pm update_host (lines 327-339)
for my $field (@array_fields) {
  next unless exists $json->{$field};

  my $new = _build_array_field($json->{$field}, $field);  # API → BackEnd format
  next unless ref $new eq 'ARRAY';

  my @rows = ($new->[0]);                           # header row
  _mark_existing_for_deletion(\@rows, ...);         # mark old records for deletion
  push @rows, @{$new}[1 .. $#{$new}];              # new records with marker=2
  $rec{$field} = \@rows;
}
```

### Concrete Example

Host has 1 existing SSHFP (id=42) and API sends 2 new SSHFP records:

```perl
$rec{sshfp_l} = [
  ['Algorithm', 'Type', 'Fingerprint', 'Comments'],  # header (ignored)
  [42, '', '', '', '', -1],                             # delete old id=42
  [0, 1, 1, 'abc123', 'comment1', 2],                 # add new
  [0, 2, 2, 'def456', '', 2],                          # add new
];
```

BackEnd processes these in order:
1. `DELETE FROM sshfp_entries WHERE id=42`
2. `INSERT INTO sshfp_entries (algorithm,hashtype,fingerprint,comment,type,ref) VALUES('1','1','abc123','comment1',1,12)`
3. `INSERT INTO sshfp_entries (algorithm,hashtype,fingerprint,comment,type,ref) VALUES('2','2','def456','',1,12)`

## Key Functions in BackEnd.pm

| Function              | Line | Purpose                                      |
|-----------------------|------|----------------------------------------------|
| `update_host`         | 2135 | Orchestrator: deletes derived fields, calls `update_record` + all `update_array_field` |
| `update_record`       | 584  | Generates `UPDATE hosts SET ...` from scalar keys |
| `update_array_field`  | 462  | Processes marker array: DELETE/UPDATE/INSERT  |
| `get_array_field`     | 421  | Builds marker array from DB query results     |
