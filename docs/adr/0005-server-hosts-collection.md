# 0005. Server-level host collection for cross-zone listing

Date: 2026-08-10
Status: Accepted

## Context

The host API was zone-scoped only: `GET /servers/{server}/zones/{zone}/hosts`.
The legacy CGI's host browser searches across zones on one server (the
"Any zone" toggle on the browse form), and hostname search is the most-used
administrator workflow, so the API needed a way to list hosts across zones.

Three placements were possible:

- A root `/hosts` collection — but hosts belong to zones which belong to
  servers, permissions are server/zone-scoped, and legacy never searches
  across servers; a root collection would invent cross-server semantics.
- An `any_zone` flag on the zone path — breaks the "path identifies the
  resource" principle; the `{zone}` placeholder becomes meaningless.
- A server-level collection `GET /servers/{server}/hosts` — mirrors the
  legacy model (search is anchored at a server, zone is only a scope) and
  keeps every resource under `/servers/{server}`.

## Decision

Add a **read-only** host collection at `GET /servers/{server}/hosts`, with
the same `{data, metadata}` envelope as every other list endpoint (ADR
0003/0004). All host CRUD stays on the zone-scoped path — a host belongs to
exactly one zone, so creation, edit, copy, move, and delete remain there.

- **Parameters:** `page` and `per_page` only. Search filters (`zone`, `type`,
  `domain`, `net`/`cidr`, field regexps, date ranges, `txt`, `has_mx`) are
  deliberately deferred; they compose and are designed together in a
  follow-up change. Zone-narrowed listing already exists at the zone path,
  so omitting `zone=` removes no capability.
- **Permission filtering** reuses `visible_zone_ids($perms, $superuser,
  $server_id)` exactly like `GET /servers/{server}/zones` (ADR 0004):
  `undef` means unfiltered (superuser, or `SAURON_PRIVILEGE_MODE == 0` with
  a server-level `R` grant), an arrayref is applied as `h.zone IN (...)`,
  an empty arrayref short-circuits to `total=0, data=[]`. The search surface
  therefore shows exactly the zones the API's zone list shows — that list,
  not the legacy browse form's embedded `user_rights` SQL, is the parity
  target.
- **Ordering** is `ORDER BY domain, id` — global alphabetical with an id
  tie-breaker, since the same domain may exist in several zones and
  pagination must be stable.
- **Row shape:** `HostListItem` gains a required `zone` (zone name) field
  in both this endpoint and the zone-scoped list. In the server list it is
  essential (the frontend composes FQDN display from `domain` + `zone`);
  in the zone list it is redundant but keeps one schema. Zone names are
  fetched in the main JOIN / one query per page — never per row (ADR 0004's
  batched-enrichment invariant).

**Parity divergence: host "type 4" records.** The legacy browse query
excludes type-4 (alias) records from its base SELECT and re-introduces them
via UNION queries that render the *target's* IP/domain — a display trick.
An API treats every host row as its own record, so this endpoint returns
type-4 records like any other; no UNION target-resolution is performed.

## Alternatives considered

- **Root `/hosts`** — rejected; no data model for it, authz across servers
  is undefined, inconsistent with the rest of the API.
- **`any_zone` flag on the zone path** — rejected; placeholder path params
  are improper REST and confuse the OpenAPI surface.
- **Filters in the same change** — rejected by decision above; keeps this
  diff to exactly the durable parts (route, authz, envelope) that are hard
  to reverse, while filter syntax remains open.

## Consequences

- New public route; clients can enumerate all hosts visible to them on a
  server with page/per_page only.
- `HostListItem` changes additively (`zone` string) for both host list
  endpoints; frontend TS types are unaffected (additive field).
- A follow-up change will introduce filter parameters (`zone`, `type`,
  `domain`, `net`/`cidr`, field regexps, `txt`, date ranges) on this path,
  all designed to compose; the SQL skeleton here (JOIN zones + allowlist
  WHERE) is built to accept them.
- Legacy browse extras (CSV export, ping sweep, alias-target UNION display)
  are out of scope permanently unless separately justified.
