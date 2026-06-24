# Array Field Codec Refactoring
#refactoring #codec #api #back-end #perl

The codec/registry layer encapsulates BackEnd wire-format knowledge into
dedicated objects, replacing the four parallel hashes
(`%BACKEND_HEADERS`, `%HEADERS`, `%BUILDERS`, `%UPDATE_COUNT`) that were
duplicated across `Server.pm`, `Zone.pm`, and `Host.pm`.

The whole layer exists to translate between two representations
bidirectionally: BackEnd's [[BackEnd-Array-Field-Wire-Format]] (a 2D array
with a header row, per-row record id, and a trailing marker integer where
`2` = keep/new and `-1` = delete) and clean API JSON (an array of objects
with named keys).

## Architecture (Layers)

```
Controllers (Host/Zone/Server)   declare WHICH fields exist + per-field shape
        |  uses
        v
SauronAPI::Codecs                 factory funcs for COMMON shapes (aml/mx/value/forwarder)
        |  builds
        v
SauronAPI::FieldCodec             OO object: decode()/encode_create()/encode_update() per field
        |  uses primitives + builders from
        v
SauronAPI::Controller::Base       low-level marker-format primitives + record builders
```

All three controllers share the same CRUD skeleton — `valid_input` →
`require_auth` → resolve server/zone → `check_perms` → BackEnd call →
`_build_*_response` — with scalars copied via `_copy_*_fields` helpers and
booleans normalized to `'t'/'f'` for BackEnd and back to JSON booleans for
responses. The codec layer makes the array-field portion of that skeleton
uniform across all three.

## What Was Replaced

Before, each controller had four hashes that had to be kept in sync:

```perl
my %BACKEND_HEADERS = (
  ns_l => ['NS', 'Comments'],          # header row for encoding
);
my %HEADERS = (
  ns_l => [qw(ns comment)],            # column names for decoding
);
my %BUILDERS = (
  ns_l => \&_build_ns_record,          # row builder coderef
);
my %UPDATE_COUNT = (
  ns_l => 3,                           # marker column position
);
```

These were passed around as hashrefs to `api_array_to_backend_create`,
`api_array_to_backend_update`, and `backend_array_to_api` from `Base.pm`.

## What replaced them

A single `%FIELDS` hash maps each field name to a `FieldCodec` instance
that bundles all four concerns:

```perl
my %FIELDS = (
  ns_l => SauronAPI::FieldCodec->new(
    backend_header => ['NS', 'Comments'],
    api_columns    => [qw(ns comment)],
    build_row      => \&_build_ns_record,
    marker_count   => 3,
  ),
);
```

The three CRUD loops become uniform method calls:

```perl
# Before (three different function signatures with hashref args):
backend_array_to_api($data, $field, \%HEADERS)
api_array_to_backend_create($json->{$f}, $f, \%BACKEND_HEADERS, \%BUILDERS, $keep_header)
api_array_to_backend_update($json->{$f}, $existing{$f}, $f, \%BACKEND_HEADERS, \%BUILDERS, \%UPDATE_COUNT)

# After (one method call per operation):
$FIELDS{$f}->decode($data)
$FIELDS{$f}->encode_create($json->{$f})
$FIELDS{$f}->encode_update($json->{$f}, $existing{$f})
```

## The Codec Objects

### `SauronAPI::FieldCodec` — `lib/SauronAPI/FieldCodec.pm`

A blessed hashref with five attributes:

| Attribute | Description |
|-----------|-------------|
| `backend_header` | Header row prepended during `_build` (e.g. `['NS', 'Comments']`) |
| `api_columns` | Clean key names for `strip_marker_format` (e.g. `['ns', 'comment']`) |
| `build_row` | Coderef mapping an API object → BackEnd data row |
| `marker_count` | Number of columns before the trailing marker (the `$count` in `UPDATE_COUNT`) |
| `create_keeps_header` | Whether `encode_create` keeps the header row (default false; true for AML) |

Three public methods:

* **`decode($backend_data)`** — calls `strip_marker_format` from `Base.pm` using `api_columns`
* **`encode_create($api_data)`** — calls `_build` (prepends header + maps `build_row`), then strips the header unless `create_keeps_header` is set. Returns data rows only for `add_array_field`.
* **`encode_update($api_data, $existing)`** — calls `_build`, then assembles header + deletion markers (via `mark_existing_for_deletion`) + new rows. Full replace-all output for `update_array_field`.

### `SauronAPI::Codecs` — `lib/SauronAPI/Codecs.pm`

Factory functions for shapes that repeat across controllers:

| Factory | Produces | Used by |
|---------|----------|---------|
| `aml()` | AML fields with `create_keeps_header => 1`, marker_count=7 | Server, Zone |
| `mx()` | MX fields, marker_count=4 | Host, Zone |
| `value(key => ..., label => ..., comment => 0\|1)` | Simple key/value fields | Server, Zone, Host |
| `forwarder(with_port => 0\|1)` | Forwarder fields | Server, Zone |

Fields with unique shapes (`ds_l`, `srv_l`, `tlsa_l`, `sshfp_l`, `printer_l`,
`ns_l`, `alias_a`, `subgroups`) are constructed inline in `Host.pm` with
`SauronAPI::FieldCodec->new(...)` since they have no reuse.

## The `ip` Special Case

The `ip` field in Host.pm was previously handled outside the array field
loop (the API uses `ips: ["1.2.3.4"]` — array of strings, not array of
objects). It now has its own codec with a `build_row` that takes a scalar:

```perl
ip => SauronAPI::FieldCodec->new(
  backend_header => ['IP', 'reverse', 'forward'],
  api_columns    => [qw(ip reverse forward)],
  build_row      => sub { [0, $_[0], 't', 't', 2] },
  marker_count   => 4,
),
```

The `ip` codec is used uniformly via `encode_create` / `encode_update` in
the create and update loops. Decode still extracts `ips` as a flat string
array (API design choice), handled manually in `_build_host_response`.

## Files Changed

| File | Change |
|------|--------|
| `lib/SauronAPI/FieldCodec.pm` | **New** — codec class |
| `lib/SauronAPI/Codecs.pm` | **New** — factory functions |
| `Controller/Zone.pm` | Refactored: 4 hashes → `%FIELDS` |
| `Controller/Server.pm` | Refactored: 4 hashes → `%FIELDS`; `keep_header` branch eliminated |
| `Controller/Host.pm` | Refactored: 4 hashes → `%FIELDS`; `ip` folded into uniform loop |
| `t/codec.t` | **New** — 17 tests, no DB required |

## Role of `Controller/Base.pm`

`Base.pm` provides the low-level pieces the codec layer is built on, unchanged
by the refactoring:

* **Marker-format primitives** — `strip_marker_format` (decode) and
  `mark_existing_for_deletion` (the delete-marker step of replace-all update).
  `FieldCodec` wraps these.
* **Record builders** — `build_aml_record`, `build_mx_record`,
  `build_value_record`, `build_forwarder_record`. These are the `build_row`
  coderefs that `Codecs.pm` wires into the `FieldCodec` objects it produces.

## See Also

- [[BackEnd-Array-Field-Wire-Format]] — detailed wire format documentation
- [[Controller-Role]] — how controllers interact with BackEnd
