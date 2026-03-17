# Authentication and Authorization Flow
#security #auth #api #permissions

The Sauron REST API implements a robust security model that integrates directly with the Sauron core database and its established privilege system.

## 1. Authentication (Identity)
The API uses **API Keys** as the primary authentication mechanism.

*   **Key Source:** API keys are stored in the `api_keys` table in the Sauron database, linked to a specific `user_id`.
*   **Header:** Clients must provide the key in the `X-API-KEY` header.
*   **Validation:** 
    1.  The `Mojolicious::Plugin::OpenAPI` intercepts the request.
    2.  The `security` callback in `SauronAPI.pm` calls a backend helper (e.g., `verify_api_key`).
    3.  The backend verifies the key (or its hash) against the database and identifies the associated user.

## 2. Authorization (Permissions)
Once a user is identified, the API enforces Sauron's multi-layered authorization model.

### Global Privilege Levels (`ALEVEL_*`)
Every user has a numerical global authorization level (0-999).
*   **Superuser (999):** Full access to everything.
*   **Admin (5-9):** Access to global configurations (VLANs, ACLs).
*   **User (1-4):** Access to history, ping, etc.
*   **Lookup:** Handled by `Sauron::BackEnd::get_user_status($uid)`.

### Specific User Rights (`user_rights`)
Granular access control defined for specific entities:
*   **Server Rights:** Access to specific DNS/DHCP servers.
*   **Zone Rights:** Read or Read/Write access to specific DNS zones.
*   **Network Rights:** Access to specific IP ranges.

## 3. Implementation in the API
The flow is orchestrated within the Mojolicious framework:

1.  **Security Callback:** Validates the key and stashes the `user_id` and `alevel` in the request context (`$c->stash`).
2.  **Controller Helpers:** Actions use a `check_perms` helper to verify access before executing logic.
    ```perl
    # Example in Zone.pm
    sub delete_zone ($self) {
      my $zid = $self->param('zone_id');
      # Check if user has RW access to this specific zone
      return unless $self->check_perms(zone => $zid, mode => 'RW');
      ...
    }
    ```

## 4. Key Advantages
*   **Consistency:** The REST API and the legacy CGI interface share the same permission logic.
*   **Security:** Key revocation is immediate in the database.
*   **Self-Service:** Users manage their own keys through the existing Sauron management interface.

## Related
- [[Database-API-Key-Authentication]]
- [[Controller-Role]]
- [[Sauron-Core-Integration]]
