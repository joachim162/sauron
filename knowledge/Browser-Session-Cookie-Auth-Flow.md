# Browser Session Cookie Authentication Flow

Authentication between a web browser (future TypeScript frontend) and Sauron REST API uses server-side sessions with HttpOnly cookies. This document describes the complete authentication flow.

## Overview

```
Browser                          sauron_api
   |                                  |
   |──── POST /auth/login ────────────► Creates session in bff_sessions
   │◄─── Set-Cookie: bff_session=xxx ◄── Stores hashed token in DB
   |                                  |
   |  (Browser stores cookie)         |
   |                                  |
   │──── GET /zones ─────────────────► CookieAuth handler:
   │       Cookie: bff_session=xxx    │   1. Read cookie
   │                                  |   2. Hash + lookup bff_sessions
   │                                  |   3. Verify not expired
   │                                  |   4. Load permissions
   │◄─── {zones: [...]} ◄──────────── 200 OK
```

## Session Creation (POST /auth/login)

1. User submits `{email, password}` to `/api/v1/auth/login`
2. Backend (`Auth.pm:login`):
   - Looks up user by email via `Sauron::BackEnd::get_user_by_email()`
   - Verifies password via `Sauron::Util::pwd_check()`
   - Checks account status (E=expired, L=locked)
   - Creates session via `Sauron::BackEnd::create_session()`:
     - Generates 32-byte random token
     - Stores SHA-256 hash in `bff_sessions.token_hash`
     - Stores plain token in cookie (never stored, only hash in DB)
     - Sets expiration (default 24h from `sauron_a_p_i.yml`)
3. Browser receives `Set-Cookie: bff_session=<token>; HttpOnly; SameSite=Lax`

## Session Validation (Subsequent Requests)

On each API request with a cookie:

1. `CookieAuth` security handler in `SauronAPI.pm:55-70`:
   ```perl
   CookieAuth => sub ($c, $definition, $scopes, $cb) {
       my $token = $c->cookie($cookie_name);           # 1. Read cookie
       my $user_id = Sauron::BackEnd::verify_session($token);  # 2. DB lookup
       # 3. Verify account status, load permissions
       $load_user_context->($c, $user_id, 'session');
       return $c->$cb();
   }
   ```

2. `verify_session()` in `Sauron/BackEnd.pm:4437-4457`:
   - Hashes the token from cookie with SHA-256
   - Looks up hash in `bff_sessions` table
   - Checks `expires_at > now()`
   - Updates `last_used` timestamp
   - Returns `user_id` if valid, `undef` if invalid/expired

## TypeScript Frontend Usage

```typescript
// Login - credentials: 'include' is required to receive/store cookies
const loginResponse = await fetch('/api/v1/auth/login', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ email: 'user@example.com', password: 'secret' }),
  credentials: 'include'  // IMPORTANT: Browser sends/receives cookies
});
const { user } = await loginResponse.json();

// Subsequent requests - cookies sent automatically
const zonesResponse = await fetch('/api/v1/zones', {
  credentials: 'include'  // Browser includes bff_session cookie
});
```

## Security Properties

| Property | Protection Against |
|----------|-------------------|
| HttpOnly | JavaScript cannot read cookie (XSS cannot steal session token) |
| SameSite=Lax | Cookie not sent on cross-site requests (CSRF protection) |
| Server-side hash | Even if DB is compromised, attacker cannot forge valid token |
| Per-request validation | Session can be revoked immediately by deleting from DB |
| `last_ip` tracking | Sessions tied to originating IP (configurable) |

## Related

- [[Authentication-and-Authorization]] - General API auth concepts
- [[Database-API-Key-Authentication]] - PAT-based auth for CLI/tools
- [[Sauron-Core-Authorization-System]] - Permission system (ALEVEL, user_rights)
- [[API-AuthN-AuthZ-Proposal]] - Original auth design proposal
- [[bff_sessions Schema]] - Session table structure (sql/bff_sessions.sql)

## Implementation Files

- `sauron_api/lib/SauronAPI/Controller/Auth.pm` - Login/logout/me endpoints
- `sauron_api/lib/SauronAPI.pm:55-70` - CookieAuth security handler
- `Sauron/BackEnd.pm:4437-4457` - verify_session()
- `Sauron/BackEnd.pm:4419-4434` - create_session()
- `sql/bff_sessions.sql` - Session table schema
