# Sauron — Glossary

## Hosts Management

- **Host** — Any record in the `hosts` table, regardless of type (1–13, 101). Not limited to type=1 ("Host").
- **Zone hosts** — The host collection scoped to a single zone (`/servers/{server}/zones/{zone}/hosts`). The home of host CRUD: create, edit, copy, move, delete all happen here because a host always belongs to exactly one zone.
- **Server hosts** — The host collection scoped to a whole server (`/servers/{server}/hosts`), listing every host the user may see across all zones. Read-only; introduced to support cross-zone host search without a root-level collection.
- **Host type** — Integer code (0–13, 101) that determines which DNS record fields are valid. Defined in `Sauron::BackEnd::get_host_types()` and mirrored in the frontend as `HOST_TYPES`.
- **Create dialog** — Compact modal form that shows `domain` + `type` always, plus extra meaningful fields per selected type. Mapping is hardcoded in the frontend.
- **Domain rename** — Changing a host's `domain` field requires navigating the frontend to the new URL; the old hostname path becomes invalid immediately.
- **Disable** — Changes a host's type from 1 to 101 (host → reservation). The `delhost` permission is required, same as Delete.
- **Enable** — Changes a host's type from 101 to 1 (reservation → host). The `host` permission is required, same as Edit.
- **Reservation** — Host type 101. A host record that no longer has DNS entries but retains its DHCP configuration (MAC, DUID, IAID). Used instead of deletion to preserve lease history.
- **Delete** — Removes the host record and all associated child entries (IPs, MX, NS, etc.). Returns 204 No Content.
- **Forward flag** — Per-address boolean on a host's IP entry controlling whether a DNS A record is generated for that IP.
- **Reverse flag** — Per-address boolean on a host's IP entry controlling whether a DNS PTR record is generated for that IP.

## Subdomain (Delegation)

- **Delegation** — Host type 2. Represents a DNS delegation (NS + DS records) to a child zone. Not a subdomain of the current zone.

## Network Management

- **Network** — A record in the `nets` table. Represents an IP network or subnet that hosts can be attached to. Referred to as "Networks" in the UI; the frontend route is `/nets` for brevity.
- **CIDR** — The `net` field. The network address in CIDR notation (e.g. `192.168.1.0/24`).
- **Netname** — The `netname` field. A short, URL-safe handle for the network (e.g. `office-net`). Used for API lookups and frontend routing.
- **Description** — The `name` field. A human-readable descriptive name for the network (e.g. `Office Network`).
- **Subnet** — A network that is a child of another network. Marked with `subnet = true`; auto-address ranges are created for subnets and virtual nets.
- **Dummy net** — A virtual subnet used to group hosts inside a real subnet. Marked with `dummy = true`; DHCP is not applicable, so the UI shows `dhcp` as `null`.
- **List mode** — One of four ways to view the networks of a server, inherited from the legacy CGI net browser: *top* (top-level nets only), *sub* (nets and subnets, excluding dummy nets), *all* (every net record), *free* (every net record plus unallocated address blocks). Viewing free blocks requires an elevated authorization level; for other users the free mode silently behaves like all.
