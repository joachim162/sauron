# Authentication and Authorization Flow
#security #auth #api #permissions #current

Detailed request-flow diagrams for each of the three authentication methods
supported by the Sauron REST API.

## 1. Proxy Auth (OIDC via Apache)

```
REQUEST ARRIVES
  ↓
[before_dispatch hook — SauronAPI.pm:23-51]
  ↓
X-Forwarded-Proto/Host headers → fix base URL
  ↓
X-Remote-User header present?
  ├─ NO → continue to session cookie check
  └─ YES
      ↓
  resolve_proxy_user() — SauronAPI.pm:96-137
      ↓
  $c->tx->remote_address in trusted IPs?
      ├─ NO → render 401 "Untrusted proxy"
      └─ YES
          ↓
      match='email' → get_user_by_email($remote_user)
      match='username' → get_user($remote_user)
          ├─ NOT FOUND → render 401 "User not found"
          └─ FOUND
              ↓
          get_user_status($user{id})
              ├─ matches /[EL]/ → render 403 "Account is no longer active"
              └─ OK
                  ↓
              load_user_context($user{id}, 'proxy')
                  ↓
              stash: api_user_id, api_perms, api_auth_method, api_superuser
  ↓
[OpenAPI security handler — SauronAPI.pm:168-185]
  ↓
api_user_id already in stash? (set by before_dispatch)
  └─ YES → return (skip BearerAuth)
  ↓
[Controller action]
  ↓
require_auth() → checks api_user_id → 401 if not set
  ↓
check_perms() → checks api_perms → 403 if insufficient
  ↓
Do the work → render response
```

## 2. Session Cookie Auth (Browser Login)

### Login Flow

```
POST /api/v1/auth/login { email, password }
  ↓
[OpenAPI security] → endpoint has no security → skip
  ↓
[before_dispatch]
  ↓ no X-Remote-User → skip proxy auth
  ↓ no bff_session cookie → skip session auth (stash not set)
  ↓
[Auth#login — Auth.pm:43-115]
  ↓
get_user_by_email($email)
  ├─ NOT FOUND → 401 "Invalid email or password"
  └─ FOUND
      ↓
  get_user_status($user{id})
      ├─ 'E' → 403 "Account has expired"
      ├─ 'L' → 403 "Account is locked"
      └─ OK
          ↓
  pwd_check($password, $user{password})
      ├─ FAIL → 401 "Invalid email or password"
      └─ OK
          ↓
  create_session($user{id}, 'password', $ip, $ttl)
      ↓ generates random token, stores SHA-256 hash in bff_sessions
      ↓
  Set-Cookie: bff_session=<token> (HttpOnly)
  render 200 with user info
```

### Authenticated Request (after login)

```
GET /api/v1/servers { Cookie: bff_session=<token> }
  ↓
[before_dispatch]
  ↓ no X-Remote-User → skip proxy auth
  ↓
  resolve_session_user() — SauronAPI.pm:139-160
      ↓
  $c->cookie('bff_session')
      ├─ not set → no auth
      └─ set
          ↓
      Sauron::BackEnd::verify_session($token)
          ├─ hash lookup in bff_sessions
          ├─ NOT FOUND → 401 "Session expired or invalid"
          └─ FOUND
              ↓
          get_user_by_id($user_id)
              ↓ loads user record
          get_user_status($user_id)
              ├─ E/L → delete session → 403 "Account is no longer active"
              └─ OK
                  ↓
          load_user_context($user_id, 'password')
  ↓
[OpenAPI security handler]
  ↓ api_user_id in stash → skip BearerAuth
  ↓
[Controller action → require_auth → check_perms → do work → render]
```

## 3. Bearer Auth (Personal Access Tokens)

```
GET /api/v1/servers { Authorization: Bearer sau_sk_abc123... }
  ↓
[before_dispatch]
  ↓ no X-Remote-User → skip proxy auth
  ↓ no bff_session cookie → skip session auth
  ↓ stash: no api_user_id
  ↓
[OpenAPI security handler — BearerAuth]
  ↓ endpoint has security: [BearerAuth: []] → handler runs
  ↓
  api_user_id already in stash?
      ├─ YES → return (already authenticated by before_dispatch)
      └─ NO
          ↓
  Extract token from Authorization header
      ├─ missing → "Authorization header not present"
      ├─ bad format → "Invalid Authorization format"
      └─ OK
          ↓
  Sauron::BackEnd::verify_pat($token)
      ├─ hash lookup in personal_access_tokens
      ├─ NOT FOUND / EXPIRED → "Invalid or expired token"
      └─ FOUND
          ↓
      update_pat_last_used($user_id, $ip) → updates last_used column
      load_user_context($user_id, 'pat')
  ↓
[Controller action → require_auth → check_perms → do work → render]
```

## 4. Authorization After Authentication

Regardless of how the user authenticated, authorization follows the same
path:

```
Controller action
  ↓
$self->require_auth
  ├─ stash('api_user_id') not set → render 401 "Not authenticated"
  └─ OK
  ↓
SauronAPI::AuthZ::check_perms($self, type => $type, $rule => $rule, ...)
  ↓
  api_perms not in stash → render 401 "Not authenticated"
  api_superuser is true → return 1 (bypass all checks)
  ↓
  type='server' → check api_perms->{server}{$id} =~ /$rule/
  type='zone'   → check api_perms->{zone}{$zid} =~ /$rule/
                  (also checks server inheritance if SAURON_PRIVILEGE_MODE==0)
  type='host'   → check zone RW + hostname mask match
  type='delhost' → check zone RW + delmask match
  type='superuser' → always 403 (superuser flag required)
  ↓
  ├─ OK → return 1
  └─ FAIL → render 403 with specific message
```

## 5. Auth Method enum values

The `api_auth_method` stash value uses these strings (matching the OpenAPI
enum in `openapi.yaml`):

| Value | Method |
|---|---|
| `proxy` | Proxy auth via X-Remote-User (OIDC) |
| `password` | Session cookie (browser login) |
| `pat` | Personal Access Token (Bearer) |

Note: the OpenAPI enum uses `proxy`, not `oidc`.

## See Also

- [[Authentication-and-Authorization]] — Overview of auth methods
- [[Sauron-Core-Authorization-System]] — Legacy permission model
- `sauron_api/lib/SauronAPI.pm` — `before_dispatch`, security handlers
- `sauron_api/lib/SauronAPI/Controller/Auth.pm` — Login, logout, me
- `sauron_api/lib/SauronAPI/AuthZ.pm` — Permission checking
