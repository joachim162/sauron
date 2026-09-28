# 0009. VLANs API

Date: 2026-09-28
Status: Accepted

## Context

A **VLAN** is Sauron's server-scoped Layer-2 segment (DHCP shared-network)
that networks belong to. Its purpose is to group subnets that share a
broadcast domain and common configuration, so shared settings are expressed
once instead of per subnet (see CONTEXT.md). The `vlans` table holds
`id, server, name, vlanno, description, comment` plus audit, and each VLAN
carries its own DHCP options (`dhcp_entries type=6` IPv4, `type=16` IPv6).

Relations: many networks → one VLAN (`nets.vlan`); `vmps.fallback` also
references a VLAN (VMPS is deprecated); the VLAN's *name* is what DHCP
generation uses for `shared-network "<name>"` blocks and what VMPS used as
`vlan-name`. The legacy CGI manages VLANs under the **Nets** menu
(`Sauron/CGI/Nets.pm`); there was no REST surface (tracked in
joachim162/sauron#32).

## Decision

**Placement and identity.** `/servers/{server}/vlans` and
`/servers/{server}/vlans/{vlan}`, server-scoped like Zones/Networks/Groups.
`{vlan}` is the **name** (unique per server); a `get_vlan_id_or_404` helper
resolves it via `BackEnd::get_vlan_by_name`. The parameter carries
`x-mojo-placeholder: '#'` because VLAN names may contain dots
(`[A-Za-z0-9_.-]+`) and the default placeholder excludes `.`; `#` (relaxed)
allows dots while still forbidding `/`. No `/assignable-vlans` picker — the
list endpoint serves as the picker for the net form.

**Two response shapes.** `VlanSummary` (list item) is `id`, `server_id`,
`name`, `vlanno`, `description`, `comment`. `Vlan` (detail) adds `dhcp_l`,
`dhcp_l6`, and audit fields. A list never carries the child arrays.

**Writes.** `name` is required and validated against `[A-Za-z0-9_.-]+`;
`vlanno` is an optional non-negative integer; `description`/`comment` are
optional strings; `dhcp_l`/`dhcp_l6` are optional `{dhcp, comment}` arrays
(entry value non-empty). Duplicate `(name, server)` → 409. `PUT` is a
partial update with replace-all array semantics; `name` is mutable (rename
changes the URL; rename conflict → 409), which is safe because everything
references a VLAN by id, not name. Updates delegate to
`BackEnd::update_vlan` (ADR 0001) after the repository loads the existing
record and merges. Creation uses `BackEnd::add_vlan` for the row but inserts
the entry arrays itself with `add_array_field`, because `add_vlan` drops the
entry comments (joachim162/sauron#45); the whole operation runs in one
transaction.

**No length caps.** The legacy form caps `name` at 32 and
`description`/`comment` at 200, but only via the browser's `maxlength` —
the server never enforced it (`form_check_field` returns for `text` with no
length check; `valid_safe_string` is used only for login). The API matches
legacy server-side behaviour and does not reject over-length values.

**Not lowercased.** The form lowercases `texthandle` fields (`conv => 'L'`),
but the API stores `name` verbatim: the Net API already treats the identical
`texthandle` netname as opaque, `import-nets` can produce mixed-case names,
and exact-name path lookups stay simple. Tracked in joachim162/sauron#43.

**Delete (corrected transaction).** Delete the VLAN's `dhcp_entries` for
**both** `type=6` and `type=16`, delete the row, detach networks
(`nets.vlan → -1`), and detach VMPS fallbacks (`vmps.fallback → -1`) in one
transaction. This fixes two legacy bugs — `BackEnd::delete_vlan` leaves
`type=16` rows orphaned and lets `vmps.fallback` dangle (breaking
`export-vmps`) — while keeping the legacy detach intent (subnets and domains
survive, just without a VLAN). The latent bugs are tracked in
joachim162/sauron#44; the API implements the corrected behaviour in
`Repository::Vlan` rather than changing `BackEnd`.

**List.** Paginated `{data, metadata}` envelope; sorts `name` (default),
`vlanno`, `description`, `comment`; filters `name`/`description`/`comment`
(regex) and `vlanno` (int); unknown params → 400.

**Authorization (legacy parity).** Reads require server `R` **and**
`level >= ALEVEL_VLANS` (superuser bypasses); create/update/delete require
`superuser` — exactly the CGI gating (`Sauron/CGI/Nets.pm`), and consistent
with the API's existing superuser gate on network writes.

**Schema layout.** `VlanFields` (shared writable base) + `VlanSummary` /
`Vlan` / `NewVlan` (`allOf VlanFields` + `required: [name]`) / `UpdateVlan`
(`allOf VlanFields`) / `VlanListResponse`, mirroring `NetFields`/`ZoneFields`
/`HostFields`. Array items are inlined (`{dhcp, comment}`).

## Alternatives considered

- **Full object on the list** — one schema, but N+1/fat-join for child
  arrays a list does not render; rejected, as for Groups (ADR 0008).
- **Path by numeric id** — no dot-encoding questions, matches the legacy
  `vlan_id`, but inconsistent with `{server}`/`{zone}`/`{group}` name
  addressing; rejected.
- **Enforce form length caps** — stricter than the legacy server, which
  never checked them; rejected to preserve parity (may be revisited).
- **Lowercase `name` for form parity** — risks splitting mixed-case names
  produced by `import-nets` and diverges from the Net API's netname
  handling; deferred to joachim162/sauron#43.
- **Fix `BackEnd::delete_vlan` in place** — benefits the CGI too, but
  changes legacy behaviour for all callers; the API instead owns the
  corrected transaction and the BackEnd bug is tracked separately (#44).
- **Relax writes to `server RW` + `ALEVEL_VLANS`** — more practical than
  superuser-only, but not legacy parity; rejected.

## Consequences

- New public resource `/servers/{server}/vlans` (+ `{vlan}`), the
  `VlanFields`/`VlanSummary`/`Vlan`/`NewVlan`/`UpdateVlan`/`VlanListResponse`
  schemas, the `vlan_*` filter/sort parameters, and a
  `get_vlan_id_or_404` helper.
- The net form gains a real VLAN source (the list endpoint) without a new
  picker endpoint.
- Deleting a VLAN is now safe: no orphaned IPv6 options and no dangling VMPS
  fallback (the legacy `BackEnd::delete_vlan` remains buggy — #44).
- Known debt:
  - joachim162/sauron#43 — `texthandle` lowercasing divergence (netname and
    vlan name).
  - joachim162/sauron#44 — `BackEnd::delete_vlan` orphans IPv6 entries and
    dangles `vmps.fallback`.
  - joachim162/sauron#45 — `BackEnd::add_vlan` drops DHCP entry comments on
    create.
  - joachim162/sauron#32 — VLAN/VMPS management umbrella (VMPS is
    deprecated).
