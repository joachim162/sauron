# Servers vs Root Servers Tables

The `servers` and `root_servers` SQL tables serve fundamentally different purposes despite both having "servers" in the name.

## `servers` — Managed BIND/DHCP Instances

The `servers` table (`sql/servers.sql`) stores **Sauron-managed server instances**. Each row represents a BIND named (and optionally DHCP) daemon whose configuration Sauron generates. Key characteristics:

- Contains global `named.conf` options: paths (`directory`, `pid_file`, `dump_file`), query sources, transfer sources, listen ports
- Stores SOA defaults: `ttl`, `refresh`, `retry`, `expire`, `minimum`
- Holds DHCP failover parameters for both IPv4 and IPv6
- Server names are globally unique: `CONSTRAINT servers_name_key UNIQUE(name)`
- A server is **role-agnostic** — it can host master zones, slave zones, forward zones, and hint zones simultaneously. The authoritative vs. recursive distinction is determined by `zones.type`, not the server itself

## `root_servers` — DNS Root Hint Records

The `root_servers` table (`sql/root_servers.sql`) stores **DNS root hint records** — the content that goes into a `named.ca` file. Each row is a single DNS record:

- `domain` — e.g., `a.root-servers.net.`
- `type` — record type, e.g., `NS` or `A`
- `value` — record value, e.g., `198.41.0.4`
- `server` — FK to `servers.id`, because each managed server can have its own root hints
- `ttl` — defaults to 3600000 (standard root hint TTL)

The `no_roots` boolean flag in the `servers` table controls whether root hint zone entries are generated for a given server.

## Relationship

```
servers (1) ──── (*) root_servers
   │                    └─ individual A/NS records for root zone
   │
   └──── (*) zones
              └─ type: M(aster), S(lave), F(orward), H(int)
```

A server entry defines *what* Sauron manages. Root server entries define *which root hints* that server uses for recursive resolution.

## See Also

- [Architecture Overview](Architecture-Overview.md)
- [User-Server-Zone Hierarchy](User-Server-Zone-Hierarchy.md)
- [Sauron Core Integration](Sauron-Core-Integration.md)
