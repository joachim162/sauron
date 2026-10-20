# AGENTS.md — Sauron DNS/DHCP Management System

Guidelines for agentic coding agents working on the Sauron codebase.

## Git & Remotes

- **`origin`** — `https://github.com/joachim162/sauron.git` (default, push here). Branches under `origin/` belong to this forked repo and are used to implement the new REST API and frontend.
- **`upstream`** — `https://github.com/tjko/sauron.git` (read-only upstream, never push). Branches under `upstream/` are the original Sauron project, including the legacy CGI implementation.
- **Create issues on:** `joachim162/sauron` (`gh issue create --repo joachim162/sauron --label <label>`)
- **Commit message format:** `type(scope): description` (e.g. `fix(ui): align nets list with hosts`, `feat(api): add vlan enrichment`, `docs: ...`)

## Build & Run

```bash
./configure && make          # Configure and build
make check                   # Syntax-check all Perl files
make clean                   # Clean build artifacts
```

**Docker (full stack):**
```bash
docker compose up -d                   # Start postgres + API + frontend + Apache
docker compose up -d sauron_api        # Restart API only
docker compose restart sauron_api      # Restart API (picks up code changes from bind mount)
docker compose logs sauron_api --tail  # View API logs
docker compose ps                      # List running containers
```

**Perl syntax checks** require Sauron modules on path. Mojolicious is not installed on the host — check API files inside Docker or skip:
```bash
PERL5LIB=/srv/sauron:/srv/sauron/sauron_api/lib perl -wc Sauron/BackEnd.pm
docker compose exec sauron_api bash -c "cd /srv/sauron && PERL5LIB=/srv/sauron:/srv/sauron/sauron_api/lib perl -wc sauron_api/lib/SauronAPI/Controller/Net.pm"
```

**API tests (inside container):**
```bash
docker compose exec sauron_api bash -c "cd /srv/sauron/sauron_api && prove -l t/net.t"
# Run multiple: prove -l t/net.t t/host.t t/authz.t
```
The full suite (`prove -l t/`) is expected to pass. Suites are controller-parity tests (they pin the observable contract — status codes, response fields, authz); put behavior tests there, not MockModule tests of internals. Note: since BackEnd commit 86e91a5, creating a type-1 host without IPs fails with code -27 (mapped to 400 by the API); test fixtures creating type-1 hosts must include an IP (marker row in BackEnd calls or `ips` in API payloads).

**Frontend:**
```bash
cd frontend && npm run build            # May fail on host due to node_modules perms; use Docker instead:
docker compose exec frontend bash -c "cd /srv/sauron/frontend && npm run build"
```
Vite dev server runs inside the `frontend` container with HMR.

**OpenAPI spec bundling:**
The API loads the bundled spec from `public/api/dist/openapi.yaml`. After editing `paths/` or `components/` files, regenerate it and **restart the API container**:
```bash
docker compose exec sauron_api bash -c "cd /srv/sauron && npx @redocly/cli bundle sauron_api/public/api/openapi.yaml -o sauron_api/public/api/dist/openapi.yaml"
docker compose restart sauron_api
```
The bundled spec is gitignored — don't commit it.

## Architecture

Sauron is Perl DNS/DHCP management with a Mojolicious REST API, React frontend (Vite + shadcn/ui), and Apache reverse proxy for OIDC.

```
Browser → Apache (HTTPS :443, mod_auth_openidc)
              ↓ Sets X-Remote-User after OIDC auth
              ↓ Proxies to API with trusted header
          Sauron API (HTTP :3000, Mojolicious)
              ↓
          PostgreSQL (database)

Frontend (Vite dev :5173) served via Apache proxy at /app/
```

**Auth flows (3 methods, coexist):**
- **BearerAuth**: Personal access tokens (`Authorization: Bearer sau_...`)
- **Session cookie**: `bff_session` from `POST /api/v1/auth/login`
- **Proxy auth**: `X-Remote-User` header from trusted Apache

**Key entry points:**
- `sauron_api/lib/SauronAPI.pm` — App startup, OpenAPI plugin, `before_dispatch` hook
- `sauron_api/lib/SauronAPI/Controller/` — One controller per resource (Auth, Host, Server, Zone, Net)
- `sauron_api/lib/SauronAPI/Repository/` — One repository per resource. Owns API data access and validation, using bound SQL for reads and unchanged `Sauron::BackEnd` write helpers where applicable. API-specific write corrections belong in repositories, not the legacy module. See `docs/adr/0001-repository-layer.md` and `docs/adr/0013-administrative-user-management.md`.
- `Sauron/BackEnd.pm` — Legacy database operations shared with CGI and CLI tools. **Frozen for API work: do not modify it, change its signatures, or add functions.** Implement API-specific behavior exclusively in the repository layer.
- `sauron_api/public/api/openapi.yaml` — Root OpenAPI spec (references `paths/` and `components/`)
- `frontend/src/api/index.ts` — Frontend API client
- `frontend/src/hooks/use-auth.tsx` — Auth context provider

## Legacy CGI Parity (behavioral source of truth)

The legacy CGI defines externally visible behavior. **API features must copy it** — validation rules, allowed values, transforms, defaults, and error cases — and study it before inventing API-specific rules. Where to look:

- **`Sauron/CGI/<Domain>.pm`** — form definition tables (`%new_server_form`, `%new_zone_form`, ...). Read these as the *validation contract*:
  - `empty=>0` — field is required
  - `type=>'enum'` + `enum=>{...}` — allowed values (e.g. zone type = M/S/H/F/C/A)
  - `iff=>[field,val]` — field only applies conditionally (maps to conditional validation; e.g. `reverse` only for master zones)
  - `default=>...` — form prefill convenience; do NOT inject it into the API without an explicit decision
- **Handler subs in the same files** (`menu_handler`, `new_zone_edit`, ...) — procedural rules that live outside the form tables (e.g. reverse-zone CIDR→arpa transform, catalog zones get `ttl=0, minimum=0` per RFC 9432).
- **`Sauron/BackEnd.pm` is NOT a validation reference.** It often accepts input the CGI form would reject (e.g. unknown zone-type chars) because the form is the gate. Enforce CGI-level rules in the API repository layer instead.
- The enforcement glue lives at the boundary: OpenAPI schemas (`required`, `readOnly`) must encode the same parity as the backend rules — history shows schema-overrides (readOnly on zone type/reverse blocked all reverse-zone creation) silently kill intended capabilities.

Pinned parity facts (codified in tests): zone type enum M/S/H/F/C/A; reverse zones master-only and always arpa-transformed from CIDR; catalog zones ttl=0/minimum=0; server create requires `name`+`hostaddr`+`directory`, while `hostname`/`hostmaster` are optional with no injected defaults.

Authentication divergences from the legacy CGI (`SAURON_AUTH_MODE`, `SAURON_AUTH_PROG`, password change gating) are recorded in `docs/adr/0012-api-password-auth-vs-legacy-auth-modes.md`. The API follows its own `auth.mode`; do not copy the legacy external-auth gates into API code without a new ADR.

## Repository Layer Rules (ADR 0001)
- Resource controllers, including User, must not call `Sauron::BackEnd` or `Sauron::DB`. All resource DB access flows through the corresponding repository. Existing authentication/session/token plumbing in Auth.pm is a legacy exception; do not extend it with resource CRUD.
- Repository functions take resolved IDs (`$server_id`, `$zone_id`), not names. Controllers resolve names via `get_server_id_or_404` / `get_zone_id_or_404` / `get_net_id_or_404` and run authz before calling the repository.
- SQL in repositories: values always bound (`db_query($sql, \@out, @bind)`); identifiers (sort/filter columns) from hardcoded whitelist maps. No interpolated user input.
- Repositories throw `SauronAPI::Exception` (single class, `status`/`kind`/`message`; shortcut constructors `not_found`, `validation`, `forbidden`, `conflict`, `persistence`). Controllers map exceptions to HTTP via the shared `render_exception` helper in `SauronAPI.pm`.

## API Pagination Format

All paginated list endpoints return the same envelope so the frontend data layer can treat them uniformly:

- `{ "data": [ ... ], "metadata": { "pagination": { "total", "page", "per_page", "total_pages" }, "sort": [], "filters": [] } }`
- `page` is 1-based; `total`/`total_pages` are **exact `COUNT(*)`** over the filtered set (stable while lists are small; reconsider if `COUNT(*)` becomes a bottleneck).
- `metadata.sort`/`metadata.filters` echo applied parameters; empty arrays when none.
- Query parameters `page` and `per_page` are validated by OpenAPI: `page >= 1`, `per_page` 1..100. Invalid values return `400`.
- Hosts, networks, servers, and zones always return the envelope (defaults `page=1`, `per_page=50`, applied in the controllers). `/servers/{server}/assignable-subnets` stays an unpaginated bare array (picker helper); frontend pickers needing complete sets loop pages of the envelope (see `fetchAllPages` in `frontend/src/api/index.ts`).
- The networks list takes a `list` query parameter (`top|sub|all|free`, default `all`) mirroring the legacy CGI net-browser list modes, filtered server-side before pagination. `free` (unallocated blocks as `id=-1` pseudo rows) requires alevel >= `ALEVEL_SHOW_UNALLOCATED_CIDRS` or superuser; for other users it silently behaves as `all`. See `docs/adr/0003-networks-list-pagination.md`.
- Server and zone lists are permission-filtered via an ID allowlist the controller derives from the perms hash (`visible_server_ids`/`visible_zone_ids` in `SauronAPI::AuthZ`); the repository applies it to both the row query and the `COUNT`, so totals reflect visibility. See `docs/adr/0004-server-zone-pagination.md`.
- The server-level host collection `GET /servers/{server}/hosts` lists hosts across all of a server's zones the caller may read, using the same `visible_zone_ids` allowlist (ADR 0005). Host CRUD stays zone-scoped; filters (`zone`, `type`, `domain`, ...) are deferred. Items carry the zone name (`zone`) as well as `zone_id`, matched for both host list endpoints. See `docs/adr/0005-server-hosts-collection.md`.
- All four list endpoints (hosts, zones, servers, networks) support declarative filters and `sort` via `SauronAPI::ListQuery` (specs in each repository, `parse_sort` for sorting; see `docs/adr/0007-host-search-filters-and-sorting.md` and `docs/host-filtering-architecture-review.md`). Unknown query params return `400` (the filter spec is the single source of truth). Networks' `list=top|sub|all|free` is a repo-local view mode (`ignore`d by the compiler), not a filter; filters apply to real net rows only, never to the `id=-1` free-block pseudo rows. Filters and the visible-ID allowlists AND-compose into the same WHERE used by rows and `COUNT(*)`.

## API Known Quirks

- **Network singleton path** is `/networks/{net}` (not `/network/{net}`). Collection: `/networks`.
- **`get_server_id_or_404` helper** is registered in `SauronAPI.pm` and should be used instead of duplicating server resolution in controllers.
- `Sauron::BackEnd::add_net` does not handle `private_flag` correctly (see GitHub issue #12). Create endpoints do not send `private_flag` until it's fixed.
- The `BackEnd::get_net_list` now returns extended columns (`net,id,name,netname,comment,no_dhcp,dummy,vlan,alevel`). The legacy [net,id,name] prefix is preserved for CGI callers.

## Code Style

- **Perl:** 2-space indent, same-line braces, private functions prefixed with `_`
- **Perl imports:** `use strict; use warnings;` then Sauron modules, then external
- **Boolean serialization:** Use `JSON::PP::true`/`JSON::PP::false` in API responses (never `\1`/`\0` — those deserialize as `{}` in JSON)
- **Perl BackEnd booleans:** Stored as `'t'`/`'f'` strings — convert when building API responses
- **No comments unless requested**
- **TypeScript:** shadcn/ui conventions, TanStack Query for data fetching, `lucide-react` for icons
- **API client** is in `frontend/src/api/index.ts`. Use TanStack Query's `useQuery`/`useMutation` for data fetching.

### Consistent style throughout `sauron_api/`

- **Follow neighboring modules, not personal preferences.** Use `Controller/Vlan.pm`, `Controller/Zone.pm`, and `Controller/User.pm` as controller examples. Do not introduce a different pattern for one resource or perform unrelated style migrations without approval.
- **Module structure:** controllers use `Mojo::Base 'Mojolicious::Controller', -signatures` and actions named for the routed operation; repositories use `strict`/`warnings`, explicit `@EXPORT_OK`, and resource-prefixed public functions. Keep private helpers `_`-prefixed.
- **Repository layout:** keep constants, filter/sort specifications, and rule maps together near the top, before public functions. Group public operations by purpose, then place all private functions in an `Internal helpers` section at the end, following `Repository/Acl.pm`. Do not interleave helpers or module-level declarations with public operations.
- **Controller flow must be explicit:** OpenAPI `valid_input` → `require_auth` → required ID resolution and authorization → repository call → response rendering. Perform authorization before accessing protected resource data. Keep special access rules (such as self-read) visible in the action.
- **Do not hide routine controller flow** behind per-controller wrappers such as `_admin`, `_list_options`, or generic action dispatchers. Existing shared application helpers (`require_auth`, ID resolution, `list_query_params`, `render_exception`) should be reused.
- **Repository errors are handled locally:** wrap each controller repository invocation in `eval`, then immediately `return $self->render_exception($@) if $@;`. The global `around_dispatch` boundary is a fallback, not a substitute for this convention.
- **Separate calls from rendering:** assign repository results to meaningful variables (`$user`, `$right`, `($rows, $meta)`) before calling `render`. Do not nest repository calls inside `render` or compress multi-step actions into long one-liners.
- **Pagination stays visible:** extract `$page` and `$per_page` in each list action with defaults `1` and `50`, and pass them explicitly alongside `$self->list_query_params`. Render envelopes as `{ data => $rows, metadata => $meta }`.
- **Repository responsibilities:** keep SQL, business validation, codecs, response shaping, transactions, and audit writes out of controllers. Reuse `SauronAPI::Repository` and `SauronAPI::ListQuery` helpers; throw `SauronAPI::Exception` for expected failures. Never leak BackEnd return codes or DB errors directly to HTTP clients.
- **Formatting:** use the existing 2-space indentation, same-line braces, spaces inside hash constructors, and blank lines between validation/authz, repository work, and rendering. Split long argument lists across lines.
- **Specs and tests:** extend the existing OpenAPI path/component organization and controller-parity test suites. A style-only refactor must preserve response bodies, status codes, authorization, and repository behavior; run the API tests to verify this.

Standard controller repository-call pattern:

```perl
my $user = eval {
  user_update($self->stash('api_user_id'), $user_id, $self->req->json // {});
};
return $self->render_exception($@) if $@;

$self->render(openapi => $user);
```

## OpenAPI Pitfalls

- **Nullability:** Any field that can return `undef` MUST have `nullable: true`. Without it, `type: string` rejects null with 500.
- **Array fields:** BackEnd uses marker-format arrays. Controllers never touch them — `SauronAPI::FieldCodec` (+ `Codecs.pm`) encodes/decodes them inside repositories. (`SauronAPI::Base`'s `_strip_marker_format` predates FieldCodec; don't use it in new code.)
- **Auth method enum:** Use `proxy` (not `oidc`) — enum is `[password, proxy, pat]`.
- **`security: []`** means no OpenAPI validation — `before_dispatch` still runs and may have set `api_user_id`.
- **OpenAPI security** only declares `BearerAuth` — proxy and session auth handled procedurally in `before_dispatch`.
- **`x-mojo-placeholder: '#'`** on path parameters allows slashes (used for CIDR in the `net` parameter).

## Docker Gotchas

- **entrypoint.sh** is copied to `/usr/local/bin/docker-entrypoint.sh` during Docker build. Edit the source at `./docker-entrypoint.sh`, then sync it into the running container:
  ```bash
  docker compose cp docker-entrypoint.sh sauron_api:/usr/local/bin/docker-entrypoint.sh
  ```
  Then restart to pick up changes.
- **Bind mount** at `.:/srv/sauron` — code changes are live inside the container, but build artifacts from `COPY` in Dockerfile are hidden by the mount.
- **Vite `server` config changes** (e.g. `allowedHosts`) are not reliably applied by the dev server's in-process config-triggered restart — the running process can keep blocking hosts even when `vite.config.ts` already allows them. Fix: `docker compose restart frontend`.
- **Apache config** is generated at startup by `apache/docker-entrypoint.sh` from env vars.
- **Test user:** `testuser@example.com` / `testuser` — has RHF requiring `dept`. Admin: `admin@example.com` / `admin`.

## Frontend State

- **Networks CRUD** fully implemented (list with create dialog, detail/edit page mirroring legacy CGI).
- **Host CRUD** works; the host edit form uses the `assignable-groups` picker for its base group and subgroups.
- **Host groups CRUD** implemented (list with create/delete + reassign, detail/edit with DHCP/DHCPv6/PRINTER entry editors).
- **VLANs CRUD** implemented (list + detail/edit with DHCP/DHCPv6 entry editors); the network form's VLAN field is a picker backed by the VLAN list.
- **Servers and Zones** have list + detail pages.
- **Templates CRUD** implemented (MX/WKS/printer-classes/HINFO list + detail pages under one Templates menu).
- **ACLs CRUD** implemented (list with built-ins, detail/edit with member rules editor, delete with reassign dialog); **TSIG keys** have a read-only list page. Both live under one ACLs menu (mirroring the CGI).
- Other pages (Users) are "Coming Soon" placeholders.
- RHF (Required Host Fields) is fully implemented: API enforces on POST/PUT, frontend shows red `*` markers, error messages display inline.
- The frontend reads RHF from `permissions.rhf` in `/auth/me` response.

## Knowledge Base & Graphify

Notes in `knowledge/` follow Zettelkasten format. A knowledge graph lives at `graphify-out/` with god nodes, community structure, and cross-file relationships.

When the user types `/graphify`, invoke the `skill` tool with `skill: "graphify"` before doing anything else.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).

## Gitignored Secrets

`sauron_api/sauron_a_p_i.yml`, `.env`, `*.key`, `*.crt`, `server.cnf` — must be created locally.
