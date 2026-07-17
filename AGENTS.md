# AGENTS.md — Sauron DNS/DHCP Management System

Guidelines for agentic coding agents working on the Sauron codebase.

<<<<<<< HEAD
<<<<<<< HEAD
## Git & Remotes

- **`origin`** — `https://github.com/joachim162/sauron.git` (default, push here). Branches under `origin/` belong to this forked repo and are used to implement the new REST API and frontend.
- **`upstream`** — `https://github.com/tjko/sauron.git` (read-only upstream, never push). Branches under `upstream/` are the original Sauron project, including the legacy CGI implementation.
- **Create issues on:** `joachim162/sauron` (`gh issue create --repo joachim162/sauron --label <label>`)
- **Commit message format:** `type(scope): description` (e.g. `fix(ui): align nets list with hosts`, `feat(api): add vlan enrichment`, `docs: ...`)

=======
>>>>>>> 8ee0faa (Refactor auth logic into shared helpers, consolidate proxy/session resolution)
=======
## Git & Remotes

- **`origin`** — `https://github.com/joachim162/sauron.git` (default, push here)
- **`upstream`** — `https://github.com/tjko/sauron.git` (read-only upstream, never push)
- **Create issues on:** `joachim162/sauron` (`gh issue create --repo joachim162/sauron --label <label>`)
- **Commit message format:** `type(scope): description` (e.g. `fix(ui): align nets list with hosts`, `feat(api): add vlan enrichment`, `docs: ...`)

>>>>>>> 9431850 (Update AGENTS.md)
## Build & Run

```bash
./configure && make          # Configure and build
make check                   # Syntax-check all Perl files
<<<<<<< HEAD
<<<<<<< HEAD
=======
make docs                    # Generate HTML docs from SQL schemas
make install                 # Install (requires root)
>>>>>>> 8ee0faa (Refactor auth logic into shared helpers, consolidate proxy/session resolution)
=======
>>>>>>> 9431850 (Update AGENTS.md)
make clean                   # Clean build artifacts
```

**Docker (full stack):**
```bash
<<<<<<< HEAD
<<<<<<< HEAD
=======
>>>>>>> 9431850 (Update AGENTS.md)
docker compose up -d                   # Start postgres + API + frontend + Apache
docker compose up -d sauron_api        # Restart API only
docker compose restart sauron_api      # Restart API (picks up code changes from bind mount)
docker compose logs sauron_api --tail  # View API logs
docker compose ps                      # List running containers
<<<<<<< HEAD
=======
docker-compose up -d                # Start postgres + API + Apache
docker-compose up -d sauron_api     # Restart API only
docker-compose build apache          # Rebuild Apache after config changes
docker-compose logs sauron_api-1     # View API logs
=======
>>>>>>> 9431850 (Update AGENTS.md)
```

**Perl syntax checks** require Sauron modules on path. Mojolicious is not installed on the host — check API files inside Docker or skip:
```bash
<<<<<<< HEAD
PERL5LIB=/home/jachym/Documents/sauron perl -wc Sauron/BackEnd.pm
>>>>>>> 8ee0faa (Refactor auth logic into shared helpers, consolidate proxy/session resolution)
=======
PERL5LIB=/srv/sauron:/srv/sauron/sauron_api/lib perl -wc Sauron/BackEnd.pm
docker compose exec sauron_api bash -c "cd /srv/sauron && PERL5LIB=/srv/sauron:/srv/sauron/sauron_api/lib perl -wc sauron_api/lib/SauronAPI/Controller/Net.pm"
>>>>>>> 66370af (docs: update AGENTS.md with current state and commit conventions)
```

<<<<<<< HEAD
<<<<<<< HEAD
**Perl syntax checks** require Sauron modules on path. Mojolicious is not installed on the host — check API files inside Docker or skip:
```bash
<<<<<<< HEAD
PERL5LIB=/srv/sauron:/srv/sauron/sauron_api/lib perl -wc Sauron/BackEnd.pm
docker compose exec sauron_api bash -c "cd /srv/sauron && PERL5LIB=/srv/sauron:/srv/sauron/sauron_api/lib perl -wc sauron_api/lib/SauronAPI/Controller/Net.pm"
```

<<<<<<< HEAD
**API tests (inside container):**
=======
=======
# Development server (morbo)
=======
**API tests:**
```bash
>>>>>>> 8ee0faa (Refactor auth logic into shared helpers, consolidate proxy/session resolution)
cd sauron_api
prove -l t/                    # All tests (minimal — only basic.t)
prove -l t/basic.t             # Single test
source sauron_api/test_api.sh  # Curl-based integration tests (requires running API + DB)
=======
**API tests (inside container):**
```bash
docker compose exec sauron_api bash -c "cd /srv/sauron/sauron_api && prove -l t/net.t"
# Run multiple: prove -l t/net.t t/host.t t/authz.t
```
`t/basic.t` and `t/auth.t` have pre-existing failures unrelated to most changes.

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
<<<<<<< HEAD
>>>>>>> 9431850 (Update AGENTS.md)
=======
docker compose restart sauron_api
>>>>>>> 66370af (docs: update AGENTS.md with current state and commit conventions)
```
The bundled spec is gitignored — don't commit it.

## Architecture

<<<<<<< HEAD
<<<<<<< HEAD
Interactive API documentation is available at `/api` (e.g., `http://localhost:3000/api`).
It fetches the OpenAPI spec from `/api/v1` and provides a live testing interface.
See `knowledge/Swagger-UI-Access.md` for troubleshooting.

>>>>>>> 38ebf0e (Implement Zone CRUD endpoints in REST API)
## Code Style Guidelines

### Perl Conventions

- **Shebang**: `#!/usr/bin/perl -I/usr/local/sauron` for main scripts
- **Strict mode**: Always `use strict;` and `use warnings;`
- **Package naming**: `Sauron::ModuleName` (CamelCase)
- **Exports**: Use `@EXPORT` for common functions, document in comments
- **Version**: Use `$VERSION = '$Id:$ ';` pattern

### Formatting

- Indentation: 2 spaces (no tabs)
- Opening brace on same line: `sub foo {`
- Variable naming: `$lowercase` for scalars, `@array`, `%hash`
- Private functions: prefix with `_` (e.g., `_internal_func`)
- Line length: Keep under 100 characters when possible

### Imports

```perl
# Standard order:
use strict;
use warnings;
use Sauron::Util;          # Core modules first
use Sauron::DB;
use Net::IP qw(:PROC);     # External modules after
use open ':locale';        # Encoding last
```

### Database Access

- Use `Sauron::DB` abstraction layer
- Use `Sauron::BackEnd` for higher-level operations
- SQL queries: use `db_query()` or `db_exec()` from Sauron::DB
- Always sanitize inputs using parameterized queries

### Error Handling

```perl
# Fatal errors
fatal("Error message");  # From Sauron::Util

# Return error codes
return -1 if (some_error_condition());

# Check database operations
fatal("Database error: $DBI::errstr") unless ($res);
```

### API Development (Mojolicious)

**Core Principles:**
- **OpenAPI-First Development:** The `openapi.yaml` file is the source of truth. All implementation must be driven by the specification.
- **API Versioning:** All endpoints must be versioned (e.g., `/api/v1/...`) to ensure backward compatibility.
- **Separation of Concerns:**
  - **Controllers:** Handle HTTP logic and request/response mapping.
  - **Logic Layer:** Interface directly with `Sauron::BackEnd` and `Sauron::Util`.
  - **Validation:** Delegated to the OpenAPI plugin to ensure strict schema compliance.
- **Statelessness:** The API must remain stateless to facilitate scaling and production deployment.

**URL Structure:**
- Resources are scoped under their parent hierarchy: `/servers/{server}/zones/{zone}/hosts/{hostname}`
- Host endpoints require `server` and `zone` in the path — hostnames are not unique across zones
- POST creates under a collection path (no resource name in path): `POST /servers/{server}/zones/{zone}/hosts` with `hostname` in request body
- GET/PUT/DELETE use the full resource path: `/servers/{server}/zones/{zone}/hosts/{hostname}`

**Schema Composition:**
- Use `allOf` to eliminate duplication. `HostFields` contains all writable scalar + array fields shared between `NewHost` and `UpdateHost`.
- `Host` (response): `allOf: [HostFields, {id, domain, fqdn, zone_id, ...}]`
- `NewHost` (create): `allOf: [HostFields, {hostname, type}]`
- `UpdateHost` (update): `allOf: [HostFields, {description}]`

**BackEnd Schema Completeness:**
- When a BackEnd `get_*` function calls `get_array_field` or `get_aml_field`, the returned array fields MUST be included in the corresponding OpenAPI response schema.
- `get_array_field` returns marker-format arrays: `[[header_row], [id, field1, field2, ..., 0]]` — the schema must reflect the actual field structure (e.g., `{ip, comment}` for forwarders, `{txt, comment}` for logging).
- `get_aml_field` returns ACL-like arrays: `[['aml', serverid], [id, mode, ip, acl, tkey, op, comment, ...]]` — these must be exposed as object arrays with all relevant properties.
- Always consult `BackEnd.pm` `get_*` functions (not just `sql/*.sql`) when defining response schemas. The SQL table only defines scalar columns; array fields are populated by `get_array_field`/`get_aml_field`/`get_field` calls.
- The `@desc` parameter in `get_array_field` calls defines the human-readable column headers but does NOT change the database query — use the actual `$fields` parameter to determine which columns are returned.

**Host Type Validation:**
- Controller enforces per-type field validation using `%TYPE_FIELDS` map
- Fields not in the type's allowed set trigger a 400 error
- Universal fields (`hostname`, `type`, `comment`, `ttl`, `class`, `grp`, `expiration`) are allowed for all types

**OpenAPI Response Schema Compliance (Critical):**
- The Mojolicious OpenAPI plugin validates every response against the schema. Mismatches cause 500 errors.
- **Nullability:** Any field that Sauron BackEnd returns as `undef` (common for optional string/text fields like `forward`, `recursion`, `dialup`, `comment`, `named_xfer`, etc.) MUST have `nullable: true` in the schema. Without this, `type: string` rejects null with `"Expected string - got null"`.
- **Array item nullability:** Properties inside array `items` (e.g., `comment` in `allow_transfer` items) also need `nullable: true` if they can be null.
- **Boolean serialization:** Perl's `\1`/`\0` references serialize as `{}` (empty objects) in Mojolicious JSON output. Use `JSON::PP::true`/`JSON::PP::false` (or `$JSON::PP::true`/`$JSON::PP::false`) for proper JSON boolean serialization. Add `use JSON::PP ();` to the controller.
- **Boolean input:** BackEnd uses `'t'`/`'f'` strings for booleans (`fix_bools` in `BackEnd.pm`). Convert to JSON booleans when building responses, and convert from JSON booleans to `'t'`/`'f'` when building BackEnd requests.
- **Debugging:** If the OpenAPI plugin rejects a response, add `print Dumper($response)` before `$self->render(openapi => $response)` to inspect the actual data. The plugin error messages include the path (e.g., `/body/allow_transfer/0/comment`) to locate the mismatched field.

**BackEnd Array Field to API Object Translation:**
- `get_aml_field` returns rows like `[id, mode, ip, acl, tkey, op, comment, marker, acl_name, key_name]` — data rows have extra join columns at the end. `get_array_field` returns `[id, data1, data2, ..., marker]` with a marker at index `$count`.
- The first element of the array is a **BackEnd header row** (e.g., `['aml', $serverid]` or `['DHCP', 'Comments']`). This header is for BackEnd internal use (BackEnd context metadata, human-readable labels) — NOT for API column names.
- **Do NOT use BackEnd header rows for API column mapping.** Instead, maintain a separate `%HEADERS` hash mapping field names to clean API property names (e.g., `allow_transfer => [qw(mode ip acl tkey op comment)]`).
- `update_array_field` in BackEnd.pm reads the marker at index `$count`. The `$count` value differs per field: AML fields use `$count=7`, simple fields use `$count=3`. Map these in a `%UPDATE_COUNT` hash.
- When building API responses, use `_strip_marker_format($data, $api_header)` where `$api_header` comes from `%HEADERS` (API column names), not from `$data->[0]` (BackEnd internal header).

**Dispatch Table Pattern for Array Fields:**
- Use `%BACKEND_HEADERS` (BackEnd internal header), `%HEADERS` (API column names), `%BUILDERS` (record builder functions), and `%UPDATE_COUNT` (marker position) as separate dispatch tables.
- `_build_array_field($api_data, $field_name)` converts API input to BackEnd format using `%BACKEND_HEADERS` and `%BUILDERS`.
- `_strip_marker_format($data, $api_header)` converts BackEnd output to API format using `%HEADERS`.
- This separation prevents the API output format from being coupled to BackEnd internal format.

**Structure:**
- Controllers in `sauron_api/lib/SauronAPI/Controller/`
- Use helpers for common operations (see `SauronAPI.pm`)
- API versioning: `/api/v1/`
- Authentication: API keys via `X-API-KEY` header

### Security Mandates (Priority 1)

- **Authentication:** 
  - Implement database-backed API key authentication.
  - Keys must be manageable via the Sauron CGI (User self-service).
  - Integrate with Sauron's existing user/password database logic found in `Sauron::BackEnd`.
- **Authorization:**
  - Map API requests to Sauron's internal privilege levels (`ALEVEL_*`) based on the user identified by the API key.
  - Enforce "Least Privilege" access control.
- **Input Sanitization:** 
  - Rely on OpenAPI schema validation for type checking.
  - Further sanitize inputs before passing them to `Sauron::BackEnd` to prevent SQL injection or command injection.
- **Error Handling:** 
  - Never leak stack traces or internal database errors to the client.
  - Use standardized RFC 7807 (Problem Details for HTTP APIs) or consistent JSON error structures.
- **TLS/SSL:** Production deployment must be strictly HTTPS.

### Extensibility & Future-Proofing

- **Modular Controllers:** Organize controllers by Sauron domain (e.g., `ZoneController`, `HostController`, `UserController`).
- **Pluggable Auth:** Design the authentication layer to be swapped or extended (e.g., adding LDAP/OIDC support later).
- **Sauron Core Integration:** Always prefer utilizing existing functions in `Sauron/*.pm` over rewriting database queries to maintain consistency with the CGI interface.

### Development Workflow

1. **Define:** Update the OpenAPI specification for new endpoints.
2. **Mock:** Use Mojolicious to serve mock responses for frontend/client testing.
3. **Implement:** Code the controller and bridge it to the Sauron backend.
4. **Validate:** Run automated tests against the OpenAPI schema.

## Project Structure
=======
Sauron is Perl DNS/DHCP management with a Mojolicious REST API and Apache reverse proxy for OIDC.
>>>>>>> 8ee0faa (Refactor auth logic into shared helpers, consolidate proxy/session resolution)
=======
Sauron is Perl DNS/DHCP management with a Mojolicious REST API, React frontend (Vite + shadcn/ui), and Apache reverse proxy for OIDC.
>>>>>>> 9431850 (Update AGENTS.md)

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
- `sauron_api/lib/SauronAPI/Controller/` — One controller per resource (Auth, Host, Server, Zone **Net**)
- `Sauron/BackEnd.pm` — 4500+ lines, all database operations. Always use this instead of raw SQL.
- `sauron_api/public/api/openapi.yaml` — Root OpenAPI spec (references `paths/` and `components/`)
- `frontend/src/api/index.ts` — Frontend API client
- `frontend/src/hooks/use-auth.tsx` — Auth context provider

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

<<<<<<< HEAD
## Gitignored Secrets

<<<<<<< HEAD
<<<<<<< HEAD
>>>>>>> cc0b391 (Add note fo further explaination of udpating host, update AGENTS.md)
```bash
docker compose exec sauron_api bash -c "cd /srv/sauron/sauron_api && prove -l t/net.t"
# Run multiple: prove -l t/net.t t/host.t t/authz.t
```
`t/basic.t` and `t/auth.t` have pre-existing failures unrelated to most changes.

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
=======
`sauron_api/sauron_a_p_i.yml`, `.env`, `*.key`, `*.crt`, `server.cnf` are gitignored — they contain credentials and must be created locally for development.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.
>>>>>>> 5d27354 (Add graphify tool to opencode for knowledge graph)
=======
Notes in `knowledge/` follow Zettelkasten format. A knowledge graph lives at `graphify-out/` with god nodes, community structure, and cross-file relationships.
>>>>>>> 9431850 (Update AGENTS.md)

When the user types `/graphify`, invoke the `skill` tool with `skill: "graphify"` before doing anything else.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
<<<<<<< HEAD
<<<<<<< HEAD
=======
>>>>>>> 9431850 (Update AGENTS.md)

## Gitignored Secrets

`sauron_api/sauron_a_p_i.yml`, `.env`, `*.key`, `*.crt`, `server.cnf` — must be created locally.
<<<<<<< HEAD
=======
`sauron_api/sauron_a_p_i.yml`, `.env`, `*.key`, `*.crt`, `server.cnf` are gitignored — they contain credentials and must be created locally for development.
>>>>>>> 8ee0faa (Refactor auth logic into shared helpers, consolidate proxy/session resolution)
=======
>>>>>>> 5d27354 (Add graphify tool to opencode for knowledge graph)
=======
>>>>>>> 9431850 (Update AGENTS.md)
