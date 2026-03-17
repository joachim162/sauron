# High-Level Operation
#architecture #workflow #deployment

Sauron is a database-driven configuration management system for DNS (BIND) and DHCP (ISC-DHCP).

## The Three-Tier Model
1.  **The Database (PostgreSQL):** The "Source of Truth" where all network state is stored.
2.  **The Interface (CGI/API):** The tools used to modify the database state.
3.  **The Generator (`sauron` CLI):** The tool that transforms database records into flat configuration files.

## Decoupled Architecture
Sauron does **not** need to run on the actual DNS or DHCP servers.
- **Management Node:** Runs Sauron, the Database, and the Web/API interface.
- **Service Nodes:** Run BIND/DHCPD. They only receive the generated text files.

## Configuration Life Cycle
1.  **Change:** User updates a host IP via [[Sauron-Core-Integration]].
2.  **Commit:** Data is saved to PostgreSQL.
3.  **Export:** The `sauron` utility is executed to generate `named.conf` or `dhcpd.conf`.
4.  **Push:** Files are moved to the Service Nodes (via `rsync`, `scp`, etc.).
5.  **Reload:** The DNS/DHCP services are reloaded to apply the new files.

## Benefits
- **Safety:** Configuration is validated before being pushed.
- **Centralization:** Manage an entire enterprise from one dashboard.
- **Audit Trail:** Changes are tracked in the database history.

## Related
- [[User-Server-Zone-Hierarchy]]
- [[Architecture-Overview]]
