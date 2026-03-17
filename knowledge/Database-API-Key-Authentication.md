# Database API Key Authentication
#security #authentication #database #sauron-core

The Sauron REST API implements a production-grade authentication mechanism using API keys stored in the central Sauron database.

## Architecture
This approach moves authentication from static configuration files to the database, enabling dynamic management and better security.

1. **Storage:** API keys are stored in a dedicated database table (e.g., `api_keys`), linked to existing Sauron `users`.
2. **Management:** Users can generate, name, and revoke their own API keys via the Sauron CGI management interface.
3. **Validation:** The REST API intercepts the `X-API-KEY` header and verifies it against the database using `Sauron::BackEnd`.

## Database Schema (Proposed)
```sql
CREATE TABLE api_keys (
    id          SERIAL PRIMARY KEY,
    user_id     INT4 NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    key_hash    TEXT UNIQUE NOT NULL, -- Store hashes for security
    name        TEXT,                 -- e.g., "SaltStack Automation"
    created_at  INT4,
    expires_at  INT4,
    last_used   INT4
);
```

## Integration Flow
1. **Header Extraction:** `Mojolicious::Plugin::OpenAPI` extracts the `X-API-KEY`.
2. **Backend Lookup:** `Sauron::BackEnd::verify_api_key($key)` is called.
3. **Session Establishment:** If valid, the user's `user_id` and `ALEVEL_*` (privilege levels) are loaded into the Mojolicious stash for authorization checks in the controllers.

## Advantages
- **Single Source of Truth:** Centralized user management.
- **Auditability:** Tracking when and where keys are used.
- **Revocability:** Immediate invalidation of compromised keys without server restarts.

## Related
- [[Authentication-and-Authorization]]
- [[Sauron-Core-Integration]]
- [[API-Entry-Point]]
