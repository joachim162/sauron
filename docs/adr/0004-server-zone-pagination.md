# 0004. Always-paginated server and zone lists with authz ID allowlists

Date: 2026-08-04
Status: Accepted

## Context

ADR 0001 paginated hosts, ADR 0003 extended the `{data, metadata}` envelope
to networks. Two list endpoints were still bare arrays: `GET /servers` and
`GET /servers/{server}/zones`. Unifying them closes the "uniform envelope"
rule — but unlike hosts and networks, these two lists apply **object-level
permission filtering after the query**:

- `list_servers` drops every server whose rule in the request's perms hash
  lacks `R` (`filter_servers`, matching `/R/i`).
- `list_zones` drops zones without a zone `R` grant; under
  `SAURON_PRIVILEGE_MODE == 0`, a server-level `R` grant exposes all zones on
  that server (`filter_zones` via `has_zone_access`, matching `/R/`).

Filtering after `LIMIT` produced the broken composition documented in ADR
0003 for client-side filtering: short pages, wrong totals, and rows stranded
beyond the first unfiltered page. The `COUNT` must run over the
permission-filtered set, so the filter must be in the `WHERE` clause.

The perm hash is not a simple column predicate: it is materialized per
request by `Sauron::BackEnd::get_permissions`, which resolves user and group
`user_rights` rows. Re-deriving that resolution in SQL would duplicate
BackEnd logic — the drift trap called out in ADR 0001.

## Decision

`GET /servers` and `GET /servers/{server}/zones` are now **always
paginated**, identical in shape to hosts and networks (defaults `page=1`,
`per_page=50`, `per_page` 1..100, applied in the controllers).

**Permission filtering moves into SQL as an ID allowlist.** The controller —
which owns authz — transcribes the existing `filter_servers`/`filter_zones`
predicates exactly (including their case-sensitivity difference) to compute
the visible object IDs from the perms hash already in memory, and passes
them to the repository, which applies `id IN (?, ...)` to both the row query
and the `COUNT`. Superuser passes no filter; an empty allowlist
short-circuits to `total=0, data=[]`. Response visibility is identical to
the old post-filter, row for row.

**Pickers fetch all pages.** Consumers that need the complete set — the
move-host zone list, the dashboard server cards, the server-form master
dropdown — loop pages of the summary envelope (page size 100) until the
total is reached. Two invariants are now codified:

- List endpoints return **base-table projections** only (already true
  everywhere); enrichment must be batched, never per row (no N+1).
- Dedicated unpaginated picker endpoints (the `assignable-subnets` pattern)
  are the documented escape hatch if a picker ever faces a set too large to
  loop. Renaming the existing collection paths was considered and rejected.

Filter-by-name on a detail-shaped collection was also considered and
rejected: the existing detail endpoints already resolve objects by name
(`zones/{zone}`, `networks/{net}`, `hosts/{host}`), so the capability exists
without new surface.

## Alternatives considered

- **Perl filter + array slice (facade pagination)** — rejected. Totals stay
  honest and no authz moves, but every page request still SELECTs and
  ships the entire table; pagination shrinks JSON, not database work, and
  diverges from hosts/networks.
- **Full authz in SQL (JOIN user_rights)** — rejected. Reimplements
  `get_permissions`' user+group resolution in a second place; silent drift
  when BackEnd's permission semantics evolve (ADR 0001).
- **Optional pagination (unpaginated summary lists for pickers)** —
  rejected. Reintroduces the dual-shape `oneOf` contract removed by ADR
  0003 and breaks the uniform-envelope rule.

## Consequences

- Breaking change: `GET /servers` and `GET /servers/{server}/zones` no
  longer return bare arrays. The frontend is the only consumer and is
  updated in the same change.
- `filter_servers` and `filter_zones` in `SauronAPI::AuthZ` are replaced by
  visible-ID helpers; the perms hash remains the single source of authz
  truth.
- Server/zone list tests now pin permission-filtered totals, not just
  pagination mechanics.
- The addendum to ADR 0001 ("Zone, Server keep their bare-array list
  responses") is superseded; ADR 0003's "assignable-subnets stays bare
  array" precedent is reaffirmed as the pattern for any future picker helper.
