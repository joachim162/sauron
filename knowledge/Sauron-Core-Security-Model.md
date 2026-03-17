# Sauron Core Security Model
#security #sauron-core #legacy #permissions #database

The legacy Sauron system (CGI and command-line tools) uses a centralized security model managed within the PostgreSQL database. This model is shared by both the interactive web interface and the backend processing scripts.

## 1. Authentication (Identity)
User identity is managed via the `users` table.

*   **Credentials:** Passwords are stored in the `password` column of the `users` table.
*   **Hashing Formats:** Sauron supports multiple hashing formats, identified by a prefix:
    *   `MD5:salt:hash` (Sauron-specific MD5)
    *   `CRYPT:salt:hash` (Standard Unix crypt)
    *   `LOCKED:...` (Account disabled)
*   **Verification:** Handled by the `pwd_check($password, $stored_hash)` function in `Sauron::Util`.

## 2. Authorization Hierarchy
Sauron uses a multi-tiered authorization system that resolves permissions in the following order:

### I. Superuser Status
Defined by the `superuser` boolean in the `users` table.
*   If `true`, the user has unconditional access to all functions and data.
*   `chk_perms` in `Sauron::CGI::Utils` returns `0` (Success/Allowed) immediately.

### II. Global Privilege Levels (`ALEVEL_*`)
For non-superusers, access to specific *functional modules* is governed by numeric levels (0-999).
*   **Definitions:** Set in `Sauron/Sauron.pm` or the main configuration.
    *   `ALEVEL_HISTORY`: Access to object history (Default: 1).
    *   `ALEVEL_VLANS`: Access to VLAN management (Default: 5).
    *   `ALEVEL_ACLS`: Access to ACL management (Default: 5).
*   **Resolution:** A user's effective level is the **highest** value found among:
    1. Rights assigned directly to the user record.
    2. Rights inherited from any `user_groups` the user belongs to.

### III. Granular Object Rights (`user_rights`)
Access to specific *data objects* is managed via the `user_rights` table.
*   **Types:**
    *   `1`: Server Rights (Access to a specific DNS/DHCP server).
    *   `2`: Zone Rights (Access to a specific DNS zone).
    *   `3`: Network Rights (Access to specific IP ranges).
*   **Modes:**
    *   `R`: Read-only access.
    *   `RW`: Read and Write access.
    *   `RWS`: Read, Write, and Super-Write (ability to override some limits).

## 3. Group Inheritance
Sauron supports `user_groups` to simplify management.
*   Users are linked to groups via `user_rights` (where `rtype = 0`).
*   A user inherits all `ALEVEL` and object-specific rights assigned to their groups.
*   Permissions are **additive**: the most permissive right (highest ALEVEL or highest Mode) wins.

## 4. Key Functions
*   `Sauron::BackEnd::get_user_status($uid)`: Returns a string representing account status (E=Expired, L=Locked, S=Superuser) and the effective numeric ALEVEL.
*   `Sauron::CGI::Utils::chk_perms($state, $type, $rule)`: The primary engine for checking if the current session (`$state`) is authorized to perform an action of `$type` according to `$rule`.

## Related
- [[Authentication-and-Authorization-Flow]]
- [[User-Server-Zone-Hierarchy]]
- [[Sauron-Core-Integration]]
