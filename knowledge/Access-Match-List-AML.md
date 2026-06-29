# Access Match List (AML)

AML = **Access Match List** — BIND's "who is allowed to do X" primitive.
Each AML is a list of match elements (an IP/CIDR, a named ACL, or a TSIG
key) carrying an allow/deny sense. In Sauron it attaches to servers,
zones, and ACL objects — **never to hosts**.

## What AML is

A match element can resolve one of three ways: by raw IP/CIDR (`ip`), by
named ACL (`acl`), or by TSIG key (`tkey`), with `op` giving the
allow/deny polarity. That tri-modal match element is *the* thing that
makes a field "AML-shaped" rather than a plain value list.

All AML fields are stored generically in one table, `cidr_entries`,
keyed by `(type, ref)`:

```perl
# Sauron/BackEnd.pm:443  get_aml_field
SELECT c.id,c.mode,c.ip,c.acl,c.tkey,c.op,c.comment, 0, a.name, k.name
FROM cidr_entries c
  LEFT JOIN acls a ON c.acl=a.id
  LEFT JOIN keys k ON c.tkey=k.id
WHERE c.type=$type AND c.ref=$ref ORDER BY c.id
```

The columns — `mode, ip, acl, tkey, op, comment` — are exactly what the
`build_aml_record` builder emits:

```perl
[0, mode, ip, acl, tkey, op, comment, 2]
```

`update_aml_field` writes them back through the generic
`update_array_field` machinery with `count=7`:

```perl
# Sauron/BackEnd.pm  update_aml_field
update_array_field("cidr_entries", 7,
                   "mode,ip,acl,tkey,op,comment,type,ref",
                   $keyname, $rec, "$type,$ref");
```

## Example

The data columns of one AML record (between the `id` and the trailing
marker) are `mode, ip, acl, tkey, op, comment`:

- **`mode`** — match-element type: `0`=CIDR, `1`=ACL, `2`=Key
- **`ip`** — CIDR/IP string (used when `mode=0`)
- **`acl`** — ACL id (used when `mode=1`)
- **`tkey`** — TSIG key id (used when `mode=2`)
- **`op`** — operator: `0`=allow (blank), `1`=`NOT` (negate/deny)
- **`comment`** — free text

So a full wire-format row is `[id, mode, ip, acl, tkey, op, comment, marker]`.

```perl
# 1. Allow a CIDR (common case)
[0, 0, '10.0.0.0/8', 0, 0, 0, 'internal net', 2]
#   ^mode=CIDR        ^acl ^key ^op=allow        ^marker=insert

# 2. Negated CIDR (deny a sub-range) -- op=1 => "! 192.168.5.0/24"
[0, 0, '192.168.5.0/24', 0, 0, 1, 'except lab', 2]

# 3. Reference a named ACL -- mode=1, value lives in `acl`
[0, 1, '', 17, 0, 0, 'trusted-acl', 2]

# 4. TSIG key -- mode=2, value lives in `tkey`
[0, 2, '', 0, 42, 0, 'transfer-key', 2]
```

At the API boundary, the clean JSON the `aml()` codec decodes to /
encodes from:

```json
[
  { "mode": 0, "ip": "10.0.0.0/8",     "op": 0, "comment": "internal net" },
  { "mode": 0, "ip": "192.168.5.0/24", "op": 1, "comment": "except lab" },
  { "mode": 1, "acl": 17,              "op": 0, "comment": "trusted-acl" },
  { "mode": 2, "tkey": 42,             "op": 0, "comment": "transfer-key" }
]
```

Those four rows compile to the BIND named.conf clause:

```
allow-transfer { 10.0.0.0/8; ! 192.168.5.0/24; trusted-acl; key transfer-key; };
```

(`mode`/`op` semantics confirmed in `Sauron/CGIutil.pm`:
`%aml_type_hash = (0=>'CIDR',1=>'ACL',2=>'Key')` and the `op` popup
`{0=>' ', 1=>'NOT'}`.)

## Where AML actually attaches (BackEnd.pm)

The `(type, ref)` key distinguishes which entity and which field a row
belongs to. `type` is a small integer constant per field:

- **Server** (`get_server`/`update_server`): `allow_transfer` (1),
  `allow_query` (7), `allow_recursion` (8), `blackhole` (9),
  `listen_on` (10), `allow_query_cache` (14), `allow_notify` (15),
  `listen_on_v6` (16)
- **Zone** (`get_zone`/`update_zone`): `allow_update` (2),
  `allow_query` (4), `allow_transfer` (5)
- **ACL object** (`type 0`): `acl`
- **Host**: *(none)*

In the API layer these are wired through the `aml()` codec factory.
`Server.pm` and `Zone.pm` both `use SauronAPI::Codecs qw(aml ...)` and
map the fields above to `aml()`; `Host.pm` deliberately omits `aml` from
its import and has no AML entries in `%FIELDS`.

## Quirk: the AML header row carries the server id

Unlike ordinary array fields, an AML field's BackEnd header row is not
column names — it is `['aml', $serverid]`. It smuggles the server id in
column 1, needed later to resolve ACL and key names. This is why the
`aml()` codec declares:

```perl
backend_header => ['aml', 0],
```

The decode path also ignores the two trailing join columns (`a.name`,
`k.name`) that `get_aml_field` appends after the marker. Because hosts
never carry AML, host codecs never deal with this special header — one
reason `Host.pm`'s codecs stay simpler than `Server.pm`/`Zone.pm`'s.

## See Also

- [[BackEnd-Array-Field-Wire-Format]] — the marker-row format AML rides on
- [[Array-Field-Codec-Refactoring]] — the `aml()` codec factory
- [[Sauron-Core-Authorization-System]] — Sauron's own permission model (distinct from BIND AMLs)
