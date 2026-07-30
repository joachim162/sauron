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
The full suite (`prove -l t/`) is expected to pass. Note: since BackEnd commit 86e91a5, creating a type-1 host without IPs fails with code -27 (mapped to 400 by the API); test fixtures creating type-1 hosts must include an IP (marker row in BackEnd calls or `ips` in API payloads).

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
- `sauron_api/lib/SauronAPI/Repository/` — One repository per resource. Data-access layer for API **reads** (own SQL, bind params) and **writes** (delegated to `Sauron::BackEnd`). See `docs/adr/0001-repository-layer.md`.
- `Sauron/BackEnd.pm` — 4500+ lines, legacy database operations. Mandatory for CGI and for all writes. Do not add new functions; new API read logic goes in repositories.
- `sauron_api/public/api/openapi.yaml` — Root OpenAPI spec (references `paths/` and `components/`)
- `frontend/src/api/index.ts` — Frontend API client
- `frontend/src/hooks/use-auth.tsx` — Auth context provider

**Repository layer rules (ADR 0001):**
- Once `SauronAPI::Repository::<X>` exists, controllers must not call `Sauron::BackEnd` or `Sauron::DB` for X. All DB access for X flows through the repository.
- Repository functions take resolved IDs (`$server_id`, `$zone_id`), not names. Controllers resolve names via `get_server_id_or_404` / `get_zone_id_or_404` and run authz before calling the repository.
- SQL in repositories: values always bound (`db_query($sql, \@out, @bind)`); identifiers (sort/filter columns) from hardcoded whitelist maps. No interpolated user input.
- Repositories throw `SauronAPI::Exception` (single class, `status`/`kind`/`message`; shortcut constructors `not_found`, `validation`, `forbidden`, `conflict`, `persistence`). Controllers map exceptions to HTTP in one place.

## API Pagination Format

All paginated list endpoints return the same envelope so the frontend data layer can treat them uniformly:

```json
{
  "data": [ ... ],
  "metadata": {
    "pagination": {
      "total": 1250,
      "page": 1,
      "per_page": 50,
      "total_pages": 25
    },
    "sort": [
      { "name": "domain", "direction": "asc" }
    ],
    "filters": [
      { "name": "host_type", "value": 1 }
    ]
  }
}
```

- `data` is the array of resource objects for the requested page.
- `metadata.pagination.total` is the total number of items matching the current query (after filters, before pagination).
- `metadata.pagination.page` is 1-based.
- `metadata.pagination.per_page` is the number of items per page.
- `metadata.pagination.total_pages` is derived from `total` / `per_page`.
- `metadata.sort` and `metadata.filters` echo the applied sort/filter parameters; they are empty arrays when none are applied, and may be extended as sorting/filtering is implemented per endpoint.
- Pagination uses **exact `COUNT(*)` totals**. This is safe for indexed, zone-scoped host lists and moderately-sized network lists. If a list grows large enough that `COUNT(*)` becomes a bottleneck, consider estimated totals or cursor pagination instead.
- Query parameters `page` and `per_page` are validated by OpenAPI: `page` must be `>= 1`, `per_page` must be `1..100`. Invalid values return `400`.

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

## OpenAPI Pitfalls

- **Nullability:** Any field that can return `undef` MUST have `nullable: true`. Without it, `type: string` rejects null with 500.
- **Array fields:** BackEnd returns marker-format arrays. Use `_strip_marker_format($data, $api_header)` with `%HEADERS` dispatch.
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
- **Apache config** is generated at startup by `apache/docker-entrypoint.sh` from env vars.
- **Test user:** `testuser@example.com` / `testuser` — has RHF requiring `dept`. Admin: `admin@example.com` / `admin`.

## Frontend State

- **Networks CRUD** fully implemented (list with create dialog, detail/edit page mirroring legacy CGI).
- **Host CRUD** works.
- Other pages (Users, Groups, ACLs, Keys, VLANs, Templates) are "Coming Soon" placeholders.
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
