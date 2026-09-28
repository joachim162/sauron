# 0008. Host groups API

Date: 2026-09-28
Status: Accepted

## Context

Host groups (`groups`) are per-server bundles of DHCP/printer/VMPS
configuration that hosts attach to. A host has one **base group**
(`hosts.grp`) plus any number of **subgroups** (`group_entries`); a group
carries its payload in shared entry tables keyed by `(type, ref)`
(`dhcp_entries` type=5/15, `printer_entries` type=1) and has a four-value
type (Normal / Dynamic Address Pool / DHCP class / Custom DHCP class), a
required authorization level (`alevel`), and a VMPS domain link (`vmps`).
See CONTEXT.md for the domain vocabulary.

The legacy CGI manages groups server-scoped (`Sauron/CGI/Groups.pm`), but
there was no REST surface. Host endpoints already referenced groups
(`grp`, `subgroups`, the `group` search filter, `host_group` enrichment in
`SauronAPI::Repository::Host`) without a way to create, read, or manage
them. This ADR records the design of that surface.

## Decision

**Placement and identity.** Groups live at
`/servers/{server}/groups` and `/servers/{server}/groups/{group}`, matching
Zones and Networks. `{group}` is the group **name** (unique per server,
`UNIQUE(name, server)`), consistent with `{server}`/`{zone}` name lookups;
a `get_group_id_or_404` helper resolves it via `BackEnd::get_group_by_name`.
The `{group}` placeholder carries `x-mojo-placeholder: '*'` because group
names are free-form text (may contain spaces or `/`) and are not charset-
restricted, preserving legacy parity; Mojolicious' wildcard placeholder
matches slashes, whereas the relaxed `'#'` (used for `{server}`/`{zone}`)
does not. `{group}` therefore must remain the final path segment.

**Two response shapes.** List items are a `GroupSummary` (`id`, `server_id`,
`name`, `type`, `alevel`, `comment`, `vmps`); the detail object `Group` adds
`vmps_name`, the three entry arrays `dhcp_l` / `dhcp_l6` / `printer_l`, and
the audit fields (`cdate`/`cuser`/`mdate`/`muser`). This follows the
Net/Server/Zone precedent: a list never carries the child arrays, so the
paginated `COUNT(*)` stays cheap and no N+1/fat-join is needed for a view
that renders four columns. Array items are `{dhcp, comment}` /
`{printer, comment}` — the same shape as the host arrays — and are declared
inline per resource, as everywhere else.

**Type as a string enum.** `type` is `normal` / `dynamic_pool` /
`dhcp_class` / `custom_dhcp_class` on the wire, mapping to DB codes
1/2/3/103 in the repository (ADR 0006 house style; Zone already uses a
string enum). Unknown slug → 400.

**Writes.** `name` is required; `type` is optional and defaults to `normal`
(NewZone precedent — the legacy new-group form prefills type=1). Everything
else is optional. `PUT` is a partial update with replace-all array
semantics (existing convention); `name` and `type` are mutable. Duplicate
`(name, server)` → 409. Writes delegate to
`BackEnd::add_group`/`update_group`/`delete_group` (ADR 0001); the
repository loads the existing group, merges the partial input, and passes
the full record. `printer_l` is valid only for `normal` groups, matching
the legacy form's `iff type=[1]`; `vmps` must be `null` or a VMPS domain of
the same server (the form's enum is server-scoped).

**Delete.** `DELETE` detaches all members by default (base `grp` → -1,
subgroup rows removed) and deletes the group; `?reassign_to=<name>` moves
members to another group first (unknown → 404, target == group → 400). The
legacy de-duplication is replicated. This mirrors the CGI's reassign/detach
transaction, since `BackEnd::delete_group` does not touch host references.

**List.** Paginated `{data, metadata}` envelope, `server R` only, **no
`alevel` ceiling** — legacy-browse parity (the picker is where legacy gates
by level). Filters `name`/`type`/`comment`/`vmps`, sorts
`name`/`type`/`alevel`, default `name` asc.

**Pickers and assignability.** `GET /servers/{server}/assignable-groups?role=base|subgroup`
returns a bare array (mirroring `assignable-subnets`) with the caller's
level ceiling and the slot's allowed types: base → `{normal, dynamic_pool}`,
subgroup → `{normal, dynamic_pool, dhcp_class}`; `custom_dhcp_class` is
never assignable. The legacy `get_group_list` is the source of truth. The
host create/update path enforces the same predicate on `grp` and
`subgroups`. On copy, only explicit overrides are validated (groups inherited
from the source host are not re-checked); and a non-zero `grp` is rejected on
host types other than 1 (host) and 5 (printer), matching the CGI form.

**Authorization.** Reads require server `R`. Writes require server `RW`
**and** a `grpmask` match on the group name (create: submitted name; update:
old and new name; delete: existing name). `grpmask` is a deny-by-default
allowlist — empty means no group may be managed. This is the documented
legacy behavior; `SauronAPI::AuthZ` gains a `grpmask` check.

## Alternatives considered

- **Full object on the list** — one schema, less code, but N+1 or a
  three-way join for data a list does not show; the only list endpoint that
  would diverge from the other three. Rejected.
- **Integer `type` on the wire** — zero mapping, but repeats the
  non-human-readable-code anti-pattern ADR 0006 removed for hosts. Rejected.
- **Numeric-id paths (`/groups/{id}`)** — no encoding concerns and matches
  the legacy `grp_id`, but inconsistent with `{server}`/`{zone}` name
  addressing. Rejected; the `'*'` placeholder handles free-form names.
- **409 when a group still has members** — safer against accidental mass
  detach, but diverges from legacy, which always allowed choosing "none".
  Rejected in favour of default-detach + `?reassign_to=`; tracked in issue
  joachim162/sauron#37.
- **Gating the list by `alevel`** — consistent with `list_nets` and the
  host `group` filter, but diverges from the legacy group browser. Deferred
  to issue joachim162/sauron#38.
- **`zone RW` for group adds (legacy menu gate)** — a server-scoped
  resource requiring a zone permission is an artifact of the CGI's
  zone-context. Rejected for `server RW`.
- **Normalize/reject redundant host membership** — cleaner data, but
  diverges from legacy, which stores and later repairs it. Store-verbatim
  chosen for now; tracked in issue joachim162/sauron#40.

## Consequences

- New public resource: `/servers/{server}/groups` (+ `{group}`), the
  `assignable-groups` picker, `GroupSummary`/`Group`/`NewGroup`/
  `UpdateGroup`/`GroupType`/`GroupListResponse` schemas, and the supporting
  `group_*` filter/sort parameters and `get_group_id_or_404` helper.
- Host writes become stricter: `grp`/`subgroups` are validated against the
  shared assignability predicate instead of being copied verbatim.
- Known debt is deliberately tracked outside this ADR:
  - joachim162/sauron#37 — revisit delete semantics (default detach vs
    explicit reassignment).
  - joachim162/sauron#38 — revisit the ungated list vs the `alevel` ceiling.
  - joachim162/sauron#39 — `modhosts` allows DHCP classes as a base group,
    contradicting the CGI rule.
  - joachim162/sauron#40 — prevent redundant host membership at the source.
  - Code TODOs: review `grpmask` deny-by-default semantics at the `AuthZ`
    check; the VMPS picker endpoint is tracked in joachim162/sauron#32 and is
    not planned because the VMPS protocol is deprecated (`vmps` stays writable
    with server-scoped validation; the UI uses a raw id input).
