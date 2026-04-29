# API AuthN/AuthZ Proposal (IMPLEMENTED)
#security #authentication #authorization #api #proposal #implemented

> **Status: IMPLEMENTED** as of `feature/rest_api`. See [[Authentication-and-Authorization]] and
> [[Authentication-and-Authorization-Flow]] for the current implementation.

The original proposal below described using Personal Access Tokens (PATs)
linked to existing `users.id` rows for automatic permission inheritance.
This was the selected approach and has been fully implemented.

## What was implemented vs. proposed

| Aspect | Proposal | Actual Implementation |
|---|---|---|
| Security scheme name | `PersonalAccessToken` | `BearerAuth` (standard OpenAPI name) |
| Token format | `sau_...` (proposed) | `sauron_sk_<64-hex>` (actual) |
| Token storage | `token_hash` SHA-256 | Same |
| OpenAPI security declaration | Global `security:` | Per-endpoint `security: [BearerAuth: []]` |
| Scopes | `[admin, read]` | Not used (empty scopes `[]`) |
| Auth handler location | Inline in `SauronAPI.pm` security | Same, with early-return for session/proxy auth |
| Controllers permission check | Inline `$perms->{server}->{$id}` | `SauronAPI::AuthZ::check_perms()` helper module |
| Session auth | Not in proposal | Added: `POST /auth/login` with `bff_sessions` table |
| Proxy auth (OIDC) | Not in proposal | Added: `X-Remote-User` via `before_dispatch` hook |

## Key additions beyond the proposal

1. **`SauronAPI::AuthZ` module** — Extracted permission-checking logic into a
   dedicated module with `check_perms`, `has_server_access`, `has_zone_access`,
   `filter_servers`, and `filter_zones`.

2. **`load_user_context` helper** — Centralized stash population with
   `api_user_id`, `api_perms`, `api_auth_method`, and `api_superuser`.
   Called by all three auth methods.

3. **`before_dispatch` hook** — Handles proxy auth (`X-Remote-User`) and
   session cookie auth (`bff_session` cookie) procedurally, before the
   OpenAPI security handler runs.

4. **Three auth methods coexist** — PAT (Bearer), session cookie, proxy auth.
   All populate the same stash fields, so controllers authorize uniformly
   regardless of auth method.

5. **`modpat` CLI tool** — Command-line utility for creating, listing, and
   revoking PATs, located at `modpat` in the project root.

## Original proposal (for reference)

### Core Principle

PATs link to existing `users.id` → automatic permission inheritance via
`get_permissions()`.

### Database Schema

```sql
CREATE TABLE personal_access_tokens (
    id          SERIAL PRIMARY KEY,
    user_id     INT4 NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash  TEXT UNIQUE NOT NULL,
    name        TEXT NOT NULL,
    created_at  INT4 DEFAULT extract(epoch from now()),
    expires_at  INT4,
    last_used   INT4,
    last_ip     TEXT
);
```

### Authentication Flow (implemented as proposed)

```
Authorization: Bearer <token> → hash lookup → user_id → get_permissions() → stash
```

### BackEnd Functions (implemented with modifications)

- `verify_pat($token)` — Returns `$user_id` or `undef` (matches proposal)
- `create_pat($user_id, $name, \%rec)` — Returns success code, stores plain token in `%rec` (matches proposal)
- `revoke_pat($token_id, $user_id)` — Deletes token row (matches proposal)
- `get_pats($user_id, \@list)` — Lists tokens for a user (matches proposal)

## See Also

- [[Authentication-and-Authorization]] — Current auth implementation
- [[Authentication-and-Authorization-Flow]] — Detailed request flow diagrams
- [[Sauron-Core-Authorization-System]] — Legacy permission model
- [[Test-Infrastructure]] — How auth is tested
- `modpat` — PAT management CLI tool
- `sql/personal_access_tokens.sql` — PAT table schema
- `sauron_api/lib/SauronAPI/AuthZ.pm` — Authorization helper module
