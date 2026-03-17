# User-Server-Zone Hierarchy
#architecture #security #permissions

Sauron uses a hierarchical model to manage DNS/DHCP data and user access.

## The Hierarchy
1.  **Server:** A logical container for a set of DNS/DHCP services (e.g., a specific BIND/DHCPD instance).
2.  **Zone:** A DNS Zone (e.g., `example.com`) that belongs to a specific **Server**.
3.  **User:** An entity that can be granted permissions at different levels of this hierarchy.

## User Scopes
- **Superuser:** Global access to all Servers and all Zones. Overrides all specific rules.
- **Server Level:** Users can be granted rights (Read/Write/All) to an entire Server and everything within it.
- **Zone Level:** Users can be restricted to specific Zones within a Server.

## The `adduser` Context
When creating a user via `[[Environment-Setup]]`:
- **Default Server/Zone:** These act as the "home" view for the user in the CGI interface.
- **Auto-Permissions:** For non-superusers, specifying a Server/Zone during creation automatically grants a baseline 'Read' (R) privilege for those objects in the `user_rights` table.

## Data Integrity
- A Zone cannot exist without being attached to a Server.
- User permissions are stored in the `user_rights` table, linking a user ID to a resource ID (Server or Zone).

## Related
- [[Sauron-Core-Integration]]
- [[Architecture-Overview]]
