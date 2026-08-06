# 0003. Always-paginated networks list with server-side list modes

Date: 2026-08-04
Status: Accepted

## Context

ADR 0001 introduced the repository layer and paginated list endpoints. Its
addendum (2026-07-30) left the networks list as an intentional exception:
`/servers/{server}/networks` paginated **opt-in** — without `page`/`per_page`
it returned the legacy bare array, and it flagged "a frontend move to
server-driven pagination (plus server-side list-mode filters)" as follow-up
work.

The reason for the exception was the frontend nets page: it ports the net
browser's four **list modes** (`top`, `sub`, `all`, `free`) from the legacy
CGI and applies the mode filters client-side (`!subnet`, `!dummy`) over the
complete result set. The legacy CGI works the same way — `browse_nets`
fetches every net and skips rows while printing.

Client-side mode filtering and server-side pagination are fundamentally
incompatible: filtering a single page of the unfiltered set produces short
pages, wrong record counts, and rows that live on later unfiltered pages
never surface in a filtered mode. As the networks list was the last
paginated endpoint returning a dual response shape (`oneOf` in the OpenAPI
spec, dual-shape tests pinned in `t/net.t`), the exception also broke the
project rule that all paginated list endpoints share one envelope.

## Decision

`/servers/{server}/networks` is now **always paginated**, identical in shape
to the hosts list:

- The bare-array response shape is deleted. Every response is the
  `{data, metadata}` envelope; the spec collapses from `oneOf` to
  `NetListResponse`.
- Defaults `page=1`, `per_page=50` are applied in the controller, mirroring
  the Host controller (`$self->param("page") // 1`).
- The four list modes move server-side as a single `list` enum query
  parameter (`top`, `sub`, `all`, `free`; default `all`), mirroring
  `param('list')` in the legacy CGI and the `?list=` state the frontend
  already keeps in its URLs. Mode semantics mirror `browse_nets` exactly:
  `top` = `dummy=false AND subnet=false`, `sub` = `dummy=false`,
  `all` = no filter, `free` = no filter plus the `unallocated_subnets`
  UNION. The mode filter is applied in SQL before `LIMIT`/`OFFSET` and the
  `COUNT`, so pagination and totals are correct per mode.
- The `free` boolean query parameter is deleted; `list=free` subsumes it.
- The authorization gating for unallocated blocks is kept as a **silent
  downgrade**: for users below `ALEVEL_SHOW_UNALLOCATED_CIDRS` (and
  non-superusers), `list=free` behaves as `list=all`. This is the direct
  translation of the CGI hiding the free-blocks menu entry and of the old
  API silently ignoring the flag.
- `/servers/{server}/assignable-subnets` keeps its bare-array response. It
  is a picker helper, not a browsable list, and stays consistent with the
  unpaginated bare-array `/servers` and `/zones` lists.
- The nets page mirrors the hosts page pagination pattern: `page`/`per_page`
  in the URL, query key over list mode + page + page size, totals from
  `metadata.pagination`, mode switch resets to page 1.

Repository internals: `net_list` retains an unpaginated path when
`page`/`per_page` are absent, consumed only by `assignable-subnets`; the
networks endpoint always passes both parameters.

## Alternatives considered

- **Keep opt-in pagination (status quo)** — rejected. Client-side mode
  filtering cannot produce correct pages or totals over a paginated set, and
  the dual `oneOf` response shape is the last exception to the uniform
  envelope rule.
- **Orthogonal boolean/filter parameters (`free`, `subnet`, `dummy`)** —
  rejected. The four values are mutually exclusive by nature, not
  independent axes, and the "list mode" concept already exists in both the
  legacy CGI (`param('list')`) and the frontend (`LIST_MODES`, `?list=`
  URLs); a single enum mirrors the domain's vocabulary.
- **403 for `list=free` below the required authorization level** — rejected.
  It breaks parity with the CGI and the old API behavior, and would make the
  same URL succeed or fail depending on authorization level for content that
  is identical except for the gap rows.
- **Paginate `assignable-subnets` too** — rejected. It is a selection helper
  with small result sets and no pagination UI; wrapping it in an envelope
  would break its consumer for no benefit.

## Consequences

- This is a **breaking API change**: the bare-array shape and the `free`
  query parameter are gone (`?free=1` is silently ignored, yielding
  `list=all`). The nets page is the only consumer and is updated in the same
  change.
- The addendum to ADR 0001 is superseded for networks: all paginated list
  endpoints now share the envelope; the "follow-up work" it names is done by
  this ADR.
- Deployments with more than 100 networks can no longer view the entire list
  in one request (`per_page` is capped at 100, as on the hosts list);
  `list=top` narrows to top-level nets without paging.
- `metadata.filters` remains `[]` (consistent with hosts); the applied
  `list` mode is not echoed there.
- `t/net.t` pins the new behavior: always-on envelope with defaults, the
  four list modes, the free-mode authorization downgrade, and 400 on an
  invalid `list` value.
