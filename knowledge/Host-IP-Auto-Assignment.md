# Host IP Auto-Assignment

How the legacy CGI picks an IP address for a host automatically instead
of requiring the user to type one in.

## The live function: `get_free_ip_by_net`

`Sauron::BackEnd::get_free_ip_by_net($serverid, $cidr, $mac, $old_ip, $ip_policy)`
(`Sauron/BackEnd.pm:3504`) is the **only** auto-assignment path actually
wired up in the CGI. Two older functions exist and are dead code:
`auto_address` (`BackEnd.pm:225`) and `next_free_ip` (`BackEnd.pm:264`)
walk the range address-by-address via `Net::IP` arithmetic; every call
site in `Hosts.pm` that used them is commented out, superseded by
`get_free_ip_by_net`'s set-based SQL approach. Don't resurrect them.

## `ip_policy` — per-net auto-assign strategy

Each row in `nets` carries an `ip_policy` column, read via
`get_net_ip_policy($serverid, $cidr)` (`BackEnd.pm:3492`, defaults to 0).
Names come from `ip_policy_names($cidr)` (`BackEnd.pm:3482`):

| value | name | applies to |
|---|---|---|
| 0 | Lowest free | any |
| 10 | Highest free | any |
| 20 | MAC based | IPv6 only, mask ≤ /80 |
| 30 | IPv4 based | IPv6 only, mask ≤ /96 |

A compatibility guard runs before dispatch and silently downgrades to
policy 0 if the required input is missing:

```perl
# Sauron/BackEnd.pm:3513
if (!$mac && $ip_policy == 20 || $ip_policy == 30 && (!$old_ip || cidr6ok($old_ip))) {
    $ip_policy = 0;
}
```
i.e. policy 20 needs a MAC, policy 30 needs a usable IPv4 `$old_ip` —
without them the call quietly falls back to "Lowest free" rather than
erroring.

## The four algorithms

- **0 – Lowest free**: reads `nets.range_start`/`range_end` — the
  configured auto-assign range, *distinct* from the net's full CIDR. If
  `range_start` is unused, returns it immediately. Otherwise one query
  finds every used IP whose `ip+1` is *not itself* used, ordered
  ascending, `LIMIT 1` — the first gap after a used block, without
  enumerating the range in Perl.
- **10 – Highest free**: mirror image, scanning down from `range_end`.
- **20 – MAC based** (IPv6): deterministically embeds the client's MAC
  into the low bits of the IPv6 address (EUI-64-style), then checks
  `a_entries` for a collision. Same MAC always maps to the same address
  within a given prefix.
- **30 – IPv4 based** (IPv6): deterministically embeds an existing IPv4
  address (`$old_ip`) into the IPv6 address, for dual-stack
  correlation. Same collision check.

## Return convention: overloaded string, not an exception

No structured error — success returns a bare IP string; failure returns
a string prefixed:

- `"S:"` — subnet-level problem (no range configured, range exhausted)
- `"H:"` — host-level problem (MAC/IPv4-derived address already in use)

Callers distinguish success from failure with `is_cidr($result)` /
`is_ip($result)`, never by inspecting the prefix themselves. Porting
this to the REST API means turning `S:`/`H:` into real HTTP semantics
(e.g. `S:` → 422/409 on the network resource, `H:` → 409 on the
host/IP resource) instead of forwarding the raw string.

## Call sites in the legacy CGI (`Sauron/CGI/Hosts.pm`)

1. **Add host** (`Hosts.pm:2169`) — if the user picked a real subnet
   from the "Subnet" dropdown (not the sentinel `'MANUAL'` option) and
   didn't type a literal IP, calls
   `get_free_ip_by_net($serverid, $data{net}, $data{ether}, '', get_net_ip_policy(...))`.
   The dropdown is built by `make_net_list` with `'MANUAL'` appended;
   selecting it makes the IP
   field mandatory and skips auto-assignment. `ip_in_use()` and
   `check_perms('ip', ...)` are still checked before insert either way.
2. **Move host** (`Hosts.pm:1118`) — same call, against the
   destination net chosen in the "Move" form (`move_net` param).
3. **Copy host** (`Hosts.pm:2327`) — pre-fills a suggested IP for the
   new record; `$mac=''` (new host has no MAC yet), and the target net
   (`preselectnet`) is derived from the *original* host's IP via
   `get_net_cidr_by_ip`.

## Related helper: `get_ip_sugg` (cross-net suggestions)

`get_ip_sugg($hostid, $serverid, $perms)` (`BackEnd.pm:3603`) goes one
step further: for a host being edited, it finds every net sharing a
VLAN with the host's current net (plus dummy/virtual nets nested in
those CIDRs), filters by alevel/permissions
([[Sauron-Core-Authorization-System]]), and calls
`get_free_ip_by_net` once per net to build an HTML `<select>` of
"netname – suggested IP" options. Used only from
`Sauron/CGIutil.pm:1090`, in the "add another IP to this host" widget
on the edit-host form.

## Design notes for the API/frontend port

- The "pick a net" vs "type a literal IP" duality is a UI concept, not
  a backend one — the API can just accept an optional `net` (CIDR or
  net id) and optional `ip`; if `ip` is absent and `net` present, call
  `get_free_ip_by_net` server-side.
- `range_start`/`range_end` being separate from the net's CIDR is easy
  to miss — a subnet can exist with `ip_policy=0` but no range
  configured at all, which surfaces as `"S:No auto address range for
  this net"` and should map to a distinct error from "range exhausted".
- `get_free_ip_by_net` only *reads* a free address — it doesn't reserve
  one. The actual uniqueness guarantee is the DB unique constraint on
  `a_entries.ip`, enforced at insert time (see the `ether_key`/
  `duid_key` conflict handling in `Hosts.pm:2234-2263`). Any API
  add-host handler needs the same "attempt insert, catch
  unique-violation, return 409" pattern rather than trusting a
  suggested IP is still free when the request lands.

## See Also

- [[BackEnd-Array-Field-Wire-Format]] — how the resulting IP is stored as a host's `ip` array field
- [[Sauron-Core-Authorization-System]] — alevel filtering used by `get_ip_sugg`
