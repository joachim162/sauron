# Sauron — Glossary

## Hosts Management

- **Host** — Any record in the `hosts` table, regardless of type (1–13, 101). Not limited to type=1 ("Host").
- **Zone hosts** — The host collection scoped to a single zone (`/servers/{server}/zones/{zone}/hosts`). The home of host CRUD: create, edit, copy, move, delete all happen here because a host always belongs to exactly one zone.
- **Server hosts** — The host collection scoped to a whole server (`/servers/{server}/hosts`), listing every host the user may see across all zones. Read-only; introduced to support cross-zone host search without a root-level collection.
- **Host type** — The record kind of a host entry, which determines which DNS record fields are valid (misc, host, delegation, mx, alias, printer, glue, alias-arec, srv, dhcp-only, zone, sshfp, tlsa, txt, naptr, caa, reservation). The API's canonical vocabulary is these string codes; the database and legacy tooling store numeric equivalents. A **reservation** is a disabled host — filtering for hosts includes reservations, exactly as the legacy browser does.
- **Create dialog** — Compact modal form that shows `domain` + `type` always, plus extra meaningful fields per selected type. Mapping is hardcoded in the frontend.
- **Domain rename** — Changing a host's `domain` field requires navigating the frontend to the new URL; the old hostname path becomes invalid immediately.
- **Disable** — Changes a host's type from 1 to 101 (host → reservation). The `delhost` permission is required, same as Delete.
- **Enable** — Changes a host's type from 101 to 1 (reservation → host). The `host` permission is required, same as Edit.
- **Reservation** — Host type 101. A host record that no longer has DNS entries but retains its DHCP configuration (MAC, DUID, IAID). Used instead of deletion to preserve lease history.
- **Delete** — Removes the host record and all associated child entries (IPs, MX, NS, etc.). Returns 204 No Content.
- **Forward flag** — Per-address boolean on a host's IP entry controlling whether a DNS A record is generated for that IP.
- **Reverse flag** — Per-address boolean on a host's IP entry controlling whether a DNS PTR record is generated for that IP.
- **Primary IP** — A host's first-assigned address (the first entry of its IP list). When a host's addresses must be reduced to one ordering value — sorting by IP, for example — the primary IP is that value. Address-less hosts sort after all addressed ones, regardless of direction.

## Host Search

- **Field search** — Filtering the host list by a pattern against one specific host attribute (e.g. MAC address, DUID, department). The legacy CGI offers this as a "search field" selector plus one pattern; the API exposes each field as its own filter parameter.
- **Free search** — A single term matched across all free-text host attributes (location, user, department, info, serial, model, misc, asset ID, HINFO hardware/software), OR-combined. Equivalent to the legacy "Search field = <ANY>" option. Not to be confused with a field search, which matches one named attribute only.
- **Domain pattern** — A case-insensitive regular expression matched against a host's hostname label (the `domain` field, e.g. `www`). On cross-zone (server-level) search it additionally matches the FQDN (label + zone), so full names like `www.example.com` are findable. A leading `*` in the pattern is literal — it matches wildcard record names like `*.foo`, it is not a regex quantifier. For an apex record (`domain` = `@`, one per zone), the FQDN is the bare zone name itself (e.g. `example.com`); zone-scoped search matches only the label, so the apex is findable there via `domain=@`.

## Subdomain (Delegation)

- **Delegation** — Host type 2. Represents a DNS delegation (NS + DS records) to a child zone. Not a subdomain of the current zone.

## Groups

- **Host group** — A server-scoped group that carries DHCP/printer definitions applied to its member hosts. The term "group" on host endpoints and in host searches always means this; never a user group.
- **Base group** — The primary group a host belongs to (one per host). Functionally indistinguishable from subgroup membership — the base/subgroup split is a legacy artifact.
- **Subgroups** — Additional group memberships a host may have beyond its base group.
- **Group membership** — Being a host's base group or one of its subgroups. Searching by group matches membership, not just the base group.
- **User group** — An access-control group governing user permissions. A distinct concept from a host group; they share only the word.

## Network Management

- **Network** — A record in the `nets` table. Represents an IP network or subnet that hosts can be attached to. Referred to as "Networks" in the UI; the frontend route is `/nets` for brevity.
- **CIDR** — The `net` field. The network address in CIDR notation (e.g. `192.168.1.0/24`).
- **Netname** — The `netname` field. A short, URL-safe handle for the network (e.g. `office-net`). Used for API lookups and frontend routing.
- **Description** — The `name` field. A human-readable descriptive name for the network (e.g. `Office Network`).
- **Subnet** — A network that is a child of another network. Marked with `subnet = true`; auto-address ranges are created for subnets and virtual nets.
- **Dummy net** — A virtual subnet used to group hosts inside a real subnet. Marked with `dummy = true`; DHCP is not applicable, so the UI shows `dhcp` as `null`.
- **List mode** — One of four ways to view the networks of a server, inherited from the legacy CGI net browser: *top* (top-level nets only), *sub* (nets and subnets, excluding dummy nets), *all* (every net record), *free* (every net record plus unallocated address blocks). Viewing free blocks requires an elevated authorization level; for other users the free mode silently behaves like all.
