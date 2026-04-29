# Authentication and Authorization in the REST API
#security #api #authentication #authorization #current

The Sauron REST API supports three authentication methods that coexist. All
three populate the same auth context in the request stash, so controllers
authorize identically regardless of how the user authenticated.

## Authentication Methods

### 1. Proxy Auth (OIDC via Apache)

```
Browser → Apache (HTTPS :443, mod_auth_openidc)
              ↓ Sets X-Remote-User after OIDC auth
              ↓ Proxies to API with trusted header
          Sauron API (HTTP :3000, Mojolicious)
```

Apache handles OIDC flow with the identity provider. After successful
authentication, it sets `X-Remote-User` to the user's email claim.
The API's `before_dispatch` hook (in `SauronAPI.pm:23-51`) picks this up
and calls `resolve_proxy_user()` which:
- Verifies the request IP is trusted (`PROXY_AUTH_TRUSTED_IPS`)
- Looks up the user by email (`get_user_by_email`)
- Checks account status (rejects expired/locked accounts)
- Calls `load_user_context($user_id, 'proxy')`

### 2. Session Cookie Auth (Browser Login)

Users can log in via `POST /api/v1/auth/login` with email and password.
On success, `Auth.pm`:
- Validates the password via `Sauron::Util::pwd_check()`
- Creates a session row in `bff_sessions` via `Sauron::BackEnd::create_session()`
- Sets a `bff_session` cookie (HttpOnly)

On subsequent requests, the `before_dispatch` hook reads the cookie and
calls `resolve_session_user()`, which verifies the token hash and calls
`load_user_context($user_id, 'password')`.

### 3. Bearer Auth (Personal Access Tokens)

```
Authorization: Bearer sau_sk_<64-hex-chars>
```

Declared in `openapi.yaml` as `BearerAuth` security scheme. Implemented
in `SauronAPI.pm:168-185` as an OpenAPI security handler. The handler:
- Extracts the token from the `Authorization` header
- Calls `Sauron::BackEnd::verify_pat()` which hashes and looks up the token
- Calls `load_user_context($user_id, 'pat')` on success

If proxy or session auth has already set `api_user_id` in the stash
(via `before_dispatch`), the BearerAuth handler short-circuits and returns
immediately — this prevents BearerAuth from rejecting requests that were
already authenticated through other means.

| Endpoint | OpenAPI `security:` | How auth happens |
|---|---|---|
| `/api/v1/auth/login` | none | Controller handles login itself |
| `/api/v1/auth/logout` | none | Controller reads cookie or returns 200 |
| `/api/v1/auth/me` | `[]` (disabled) | `before_dispatch` only (proxy/session) |
| `/api/v1/servers/*` | `[BearerAuth: []]` | OpenAPI handler + `before_dispatch` |
| `/api/v1/servers/{s}/zones/*` | `[BearerAuth: []]` | OpenAPI handler + `before_dispatch` |
| `/api/v1/servers/{s}/zones/{z}/hosts/*` | `[BearerAuth: []]` | OpenAPI handler + `before_dispatch` |

`security: []` means "no OpenAPI security validation" — the BearerAuth
handler does NOT run. Auth is handled procedurally by `before_dispatch`.
PAT-based access does NOT work on `/auth/me` for this reason.

## The Auth Context (Stash)

All three methods converge at `load_user_context()` (`SauronAPI.pm:70-85`):

```perl
$c->stash(
  api_user_id     => $user_id,
  api_perms       => \%perms,       # from get_permissions()
  api_auth_method => $auth_method,  # 'proxy' | 'password' | 'pat'
  api_superuser   => $superuser,    # 1/0 from users.superuser
);
```

Controllers never check which auth method was used. They check:
- `$c->stash('api_user_id')` — is the user authenticated?
- `$c->stash('api_perms')` — what can they access?

## Authorization

### Helper Module

`SauronAPI::AuthZ` (`sauron_api/lib/SauronAPI/AuthZ.pm`) provides:

```perl
use SauronAPI::AuthZ qw(check_perms filter_servers filter_zones);

# Check specific permission
return unless check_perms($self, type => 'server', server_id => $id, rule => 'RW');

# Filter lists by what the user can see
filter_servers($perms, $superuser, \@servers);
filter_zones($perms, $superuser, $server_id, \@zones);
```

### Permission Types (`check_perms`)

| `type` | Used for | Required rule | Where |
|---|---|---|---|
| `superuser` | Create/delete server | — | `Server.pm:336,445` |
| `server` | Read/update server | R/RW | `Server.pm:318,393` |
| `zone` | Read/update zone | R/RW | `Zone.pm:301,405` |
| `server` + `RW` | Create zone, delete zone (RWS) | RW/RWS | `Zone.pm:321,470` |
| `zone` + `R` | Get host | R | `Host.pm:145` |
| `zone` + `RW` | Create host | RW | `Host.pm:175` |
| `host` | Update host | zone RW + hostname mask match | `Host.pm:356` |
| `delhost` | Delete host | zone RW + delmask match | `Host.pm:266` |
| `flags` | Check record type flag | flag name match | Not yet used in API |
| `level` | Check authorization level | numeric threshold | Not yet used in API |

### Privilege Mode Inheritance

When `$SAURON_PRIVILEGE_MODE == 0` (default in `t/config`), server-level
rights implicitly grant zone-level rights of the same type. A user with
server `RW` automatically has zone `RW` for all zones on that server,
without any `user_rights` rows for those zones.

This is handled by `SauronAPI::AuthZ::has_zone_access()` (`AuthZ.pm:131-141`).

### Superuser Bypass

`check_perms()` returns `1` immediately if `api_superuser == 1`. Superusers
bypass ALL permission checks — they can create/delete servers, modify any
zone, delete any host, etc.

The `superuser` boolean is stored in `users.superuser` (PostgreSQL boolean,
normalized to `'t'`/`'f'` by `fix_bools()`). The API converts it using:
```perl
$superuser = ($user{superuser} && $user{superuser} eq 't') ? 1 : 0;
```
The `eq 't'` check is critical — Perl's truthiness treats `'f'` as true.

## How Authorization is Wired into Controllers

Every protected controller action follows this pattern:

```perl
sub action ($self) {
  return unless $self->openapi->valid_input;   # OpenAPI schema validation
  return unless $self->require_auth;           # 401 if not authenticated
  # Resolve name → ID (404 if not found)
  return unless check_perms($self, type => ..., rule => ...);  # 403 if not authorized
  # Do the actual work
  $self->render(openapi => $result);
}
```

`require_auth` (`SauronAPI.pm:87-93`) checks `$c->stash('api_user_id')`
and renders 401 if not set.

## See Also

- [[Authentication-and-Authorization-Flow]] — Detailed flow for each auth method
- [[Sauron-Core-Authorization-System]] — Legacy permission model (user_rights table)
- [[Test-Infrastructure]] — How auth is tested in the test suite
- [[Test-Mojo-Guide]] — Testing auth in practice
- `sauron_api/lib/SauronAPI.pm` — `before_dispatch`, `load_user_context`, `require_auth`
- `sauron_api/lib/SauronAPI/AuthZ.pm` — `check_perms`, `filter_servers`, `filter_zones`
- `sauron_api/lib/SauronAPI/Controller/Auth.pm` — Login, logout, me endpoints
