# Sauron — Glossary

## Hosts Management

- **Host** — Any record in the `hosts` table, regardless of type (1–13, 101). Not limited to type=1 ("Host").
- **Host type** — Integer code (0–13, 101) that determines which DNS record fields are valid. Defined in `Sauron::BackEnd::get_host_types()` and mirrored in the frontend as `HOST_TYPES`.
- **Create dialog** — Compact modal form that shows `domain` + `type` always, plus extra meaningful fields per selected type. Mapping is hardcoded in the frontend.
- **Domain rename** — Changing a host's `domain` field requires navigating the frontend to the new URL; the old hostname path becomes invalid immediately.
- **Delete** — Removes the host record and all associated child entries (IPs, MX, NS, etc.). Returns 204 No Content.

## Subdomain (Delegation)

- **Delegation** — Host type 2. Represents a DNS delegation (NS + DS records) to a child zone. Not a subdomain of the current zone.
