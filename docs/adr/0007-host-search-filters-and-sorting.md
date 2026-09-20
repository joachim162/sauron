# 0007. Host search filters and sorting

Date: 2026-08-11
Status: Accepted

## Context

The legacy CGI host browser (`Sauron/CGI/Hosts.pm`, "browse" handler) is the
most-used administrator workflow: a rich search over hosts by type, group,
network, hostname pattern, per-field patterns, date ranges, TXT content, and
MX template, sorted by hostname or IP. ADR 0005 introduced the server-scoped
host collection but deliberately deferred all search parameters; this ADR
settles them.

Design guidance is *The Design of Web APIs* §9.6: filters must be guessable
and map to returned data (9.6.1), support fuzzy values (9.6.2), offer `q` for
free search (9.6.3), be minimized (9.6.4), sort with `field:direction` and
helpful defaults (9.6.5), and echo applied filter/sort/pagination metadata
(9.6.7). Legacy parity (AGENTS.md) governs semantics; the book governs shape.

Both list endpoints receive the same filter set symmetrically:
`GET /servers/{server}/hosts` and `GET /servers/{server}/zones/{zone}/hosts`.

## Decision

### Filters

| Parameter | Matches | Notes |
| --- | --- | --- |
| `q` | OR-across-fields free search | case-insensitive regex over the hostname (label and FQDN) plus location, user, dept, info, serial, model, misc, asset ID, HINFO hw/sw. Superset of the legacy `<ANY>` field search (divergence 9). |
| `domain` | hostname label regex | case-insensitive regex. Server-scoped path also matches the FQDN (label + zone) so full names are findable; an apex record (`@`) matches the bare zone name — the same expression used to build the returned `fqdn`. Leading `*` is literal (wildcard record names like `*.foo`). |
| `type` | string enum (ADR 0006) | exact match; `host` includes `reservation` (legacy parity); omitted = all types. |
| `ip` | address or CIDR block | bare address = exact match; block = containment (`<<=`). |
| `group` | host group **name** | per-server name resolution; matches base group **or** any subgroup (legacy parity). Unknown or above the caller's alevel → 400. |
| `ether`, `duid`, `iaid`, `info`, `huser`, `location`, `dept`, `model`, `serial`, `misc`, `asset_id`, `hinfo` | the named column, regex | `hinfo` matches hw **or** sw; `ether`/`duid` are normalized (uppercased, separators stripped) and `iaid` matched numerically — legacy transforms kept. |
| `txt` | the host's TXT entries | case-insensitive regex. **Matches hosts that *carry* a matching TXT entry — it does not select objects of type `txt`** (use `type` for that). Implies the TXT-capable types (`host`, `mx`, `alias`, `alias_arec`) unless `type` is given explicitly; an explicitly incompatible `type` yields an empty set rather than silently ignoring the filter. |
| `mx` | MX template name | case-insensitive regex, join restricted to the host's zone. **Matches hosts whose MX template matches — it does not select objects of type `mx`** (use `type` for that). |
| `{dhcp_date,dhcp_last,cdate,mdate,expiration}_{from,to}` | inclusive ISO 8601 date range | `from` = ≥, `to` = ≤ end-of-day. **NULL timestamps never match any range.** |

Filters compose with AND and always compose **inside** the
`visible_zone_ids` permission restriction (ADR 0004/0005); totals remain
exact `COUNT(*)` over the filtered set (ADR 0003). All values are bound
parameters; filter targets are hardcoded identifier maps (ADR 0001). Invalid
regex, invalid IP/CIDR, invalid date, unknown type/group, or an unknown sort
field → 400.

### Regex dialect and resource limits

The patterns are evaluated by PostgreSQL `~*`, not by Perl — the dialects
differ (`\K`, `\R` and possessive quantifiers are valid Perl but invalid
PostgreSQL ARE). Patterns are therefore **validated by the database engine
itself** (a one-row probe compile) and SQLSTATE 2201B/2201C map to a 400;
no Perl-side regex compilation is involved. Pattern length is capped at
the legacy CGI limits (40 characters, TXT 80) via OpenAPI `maxLength`, and
the filtered row/count queries run under a defensive `statement_timeout`
so an authenticated client cannot pin database resources with an expensive
pattern.

A `zone` filter is **deferred**: a required-ish zone filter is a missing path
resource (the book's own example in 9.6.4) — the zone-scoped endpoint already
exists.

### Sorting

`sort=field[:asc|desc][,...]`, direction defaults to `asc`, multiple keys
comma-separated. Whitelist: `domain`, `ip`, `type`, `ether`, `cdate`, `mdate`,
`dhcp_date`, `expiration`. Default: `domain:asc` with an invisible `id`
tiebreaker for stable pagination (ADR 0005). `ip` orders by the host's
**primary IP** (first entry of its IP list) so a host stays one row regardless
of address count; address-less hosts sort last in both directions.

### Metadata echo (book §9.6.7)

`metadata.sort` and `metadata.filters` stop being empty arrays:

```json
"sort": [ { "name": "domain", "direction": "asc" } ],
"filters": [ { "name": "type", "value": "host" },
              { "name": "ip", "value": "10.0.0.0/8" } ]
```

`sort` echoes the applied ordering or the default when the parameter is
omitted; `filters` echoes only explicitly applied filters (they have no
defaults), `[]` when none.

### Response enrichment

- `HostListItem` gains `fqdn` (label + zone) so `domain` and its FQDN matching
  map to returned data on both paths.
- `Host`/`HostListItem` gain `host_group` (base group name), included only when
  the group's alevel does not exceed the caller's — the `vlan_name` gating
  precedent. The `grp` id field keeps its current name in this change; the
  `grp` → `host_group_id` rename is deferred to a separate change that can
  also touch the write path.

### Deliberate divergences from legacy

1. **Type is a string enum**, not an integer (ADR 0006).
2. **No alias UNION display trick**: any-type listing shows type-4 records as
   their own rows (carried over from ADR 0005).
3. **`txt` + incompatible explicit type → empty set**; legacy silently ignores
   the filter.
4. **`mx` pattern is case-insensitive**; legacy matches case-sensitively.
5. **Date upper bounds exclude NULL timestamps**; legacy's `-YYYYMMDD` form
   also returns rows whose timestamp is NULL.
6. **Unknown group → 400**; legacy returns a silent empty set (and the
   group's existence is not leaked when it is above the caller's alevel).
7. **Default sort is `domain:asc`**; legacy's browse default is by IP (ADR 0005
   already ruled this for the API).
8. **`ip` sort keeps one row per host** (primary IP); legacy's join emits one
   row per (host, address) pair.
9. **`q` includes the hostname** (label and FQDN) in addition to the legacy
   `<ANY>` metadata fields: the motivating workflow — finding a host by name —
   must work through the free search bar, which exposes only `q` and `type`.
10. **Regex patterns are PostgreSQL ARE**, engine-validated, length-capped
    (40; TXT 80) and executed under a statement timeout; the legacy CGI
    accepts Perl-flavoured patterns up to its HTML input limits.
11. **Apex records (`@`) render as their FQDN.** Legacy displays the apex
    record as `@.zone` in the any-zone browser — a naive
    `a.domain || '.' || z.name` concatenation, not a valid DNS name — and
    its domain filter matches the label only. The API renders the bare
    zone name in `fqdn` (list and detail responses) and matches that same
    expression in the server-scoped `domain` filter and in `q`, so a
    client can round-trip a returned `fqdn` into a filter. The zone-scoped
    `domain` filter stays label-only (legacy parity); the apex is
    findable there via `domain=@`.

## Alternatives considered

- **CGI-shaped combo params** (`field` + `pattern` selector, date selector +
  compact range string) — faithful to the legacy form but unguessable;
  rejected per book 9.6.1.
- **Filtering by group id** — consistent with stored references, but ids are
  undiscoverable (no Groups endpoint) and useless to humans typing searches;
  names are resolvable per-server. Stored references stay id-based.
- **`net` + `cidr` as separate params** — redundant; any net-based query is a
  CIDR query against a discoverable nets list; rejected per book 9.6.4.
- **Strict CGI parity for apex records** (`fqdn` = `@.zone`, label-only
  filtering everywhere) — faithful, but it publishes a pseudo-FQDN that is
  not a valid DNS name and breaks the round-trip between the returned
  `fqdn` and the `domain` filter (the original review finding); rejected.
- **`has_mx` boolean** — subsumed by `mx=.`; rejected per 9.6.4.
- **Query DSL in `q`** (Lucene-style) — overkill for the target workflows;
  plain regex over the fixed column set, composable with discrete filters.
