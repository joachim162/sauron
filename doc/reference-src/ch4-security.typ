#import "defs.typ": note, warn

= The Security Model <security>

Sauron's authentication and authorization are entirely database-driven and
shared by every interface — legacy CGI, CLI tools, and the REST API all
resolve identity and rights through the same `users` / `user_groups` /
`user_rights` tables and the same BackEnd functions. This chapter is the
authoritative description of that model.

== Authentication

=== Password storage and verification

`users.password` holds one of:

#table(
  columns: (auto, 1fr),
  table.header([Format], [Meaning]),
  [`MD5:salt:hash`], [Sauron's salted MD5 scheme (`pwd_make_md5`),
    the default (`$SAURON_PWD_MODE = 1`).],
  [`CRYPT:salt:hash`], [Classic Unix `crypt(3)` (`pwd_make_unix`).],
  [`LOCKED:...`], [Account administratively disabled — any prefix
    mismatch fails verification, and the convention is to prepend
    `LOCKED:` to lock without losing the old hash.],
)

`Sauron::Util::pwd_check($password, $stored)` dispatches on the prefix
and returns 0 on success. Three authentication *modes* exist for the
legacy CGI, selected by `$SAURON_AUTH_MODE`:

- *Mode 0 (internal)* — the login form checks `pwd_check` against the
  `users` row; or, if `$SAURON_AUTH_PROG` is set, an external program is
  invoked with the username and password (`pwd_external_check`) so sites
  can plug in RADIUS/LDAP/Kerberos.
- *Mode 1 (web-server auth)* — the CGI trusts `REMOTE_USER` from Apache
  (basic auth, Kerberos, OIDC…) and skips password checks entirely; the
  user must still exist in `users`.

Account expiration uses `users.expiration` (from `common_fields`): an
epoch in the past blocks login, and the CGI warns users two weeks ahead.
`get_user_status($uid)` condenses this into a status string (Expired /
Locked / Superuser + effective authorization level) that the API also
uses to reject dormant accounts.

=== Sessions and tokens

Three session mechanisms coexist, all in BackEnd:

- *Legacy CGI sessions (`utmp`)* — a random 32-hex cookie
  (`sauron-$SERVER_ID`) keys a `utmp` row holding the entire UI state.
  `fix_utmp($timeout, …)` reaps idle sessions
  (`$SAURON_USER_TIMEOUT`, default 1 h). By default the session is bound
  to the client IP (`$SAURON_NO_REMOTE_ADDR_AUTH = 0`), and a session id
  (`new_sid`) groups all history entries of one login.
- *Personal Access Tokens (`personal_access_tokens`)* — API bearer
  tokens of the form `sau_sk_<64 hex>`. `create_pat($uid, $name,
  $expiry)` returns the cleartext once and stores only a hash;
  `verify_pat($token)` resolves it back to a user id;
  `revoke_pat`, `get_pats`, `update_pat_last_used` complete the life
  cycle. The `modpat` CLI manages them from the shell.
- *Frontend cookie sessions (`bff_sessions`)* — `create_session` /
  `verify_session` / `delete_session` / `delete_user_sessions` /
  `cleanup_expired_sessions` implement HttpOnly-cookie sessions for the
  new frontend's login flow.

== Authorization

Authorization resolves in three tiers, checked in order:

=== Tier 1: superuser

`users.superuser` (boolean — remember, `'t'`/`'f'`). Superusers bypass
*every* subsequent check: all servers, all zones, all hosts, all
administrative functions. The CGI caches it as
`$state{superuser} eq 'yes'`; permission checks return "allowed"
immediately.

=== Tier 2: authorization levels (ALEVEL)

Numeric privilege levels 0--999 gate *functional areas* rather than data
objects. A user's effective level is the *maximum* of all `rtype = 6`
rights granted to them directly or via their user groups
(`$perms{alevel}`). Defaults from `Sauron.pm` (overridable in `config`):

#table(
  columns: (auto, auto, 1fr),
  table.header([Setting], [Default], [Gates]),
  [`ALEVEL_VLANS`], [5], [VLAN and VMPS management],
  [`ALEVEL_ACLS`], [5], [ACL and TSIG key management],
  [`ALEVEL_RESERVATIONS`], [1], [Adding host reservations],
  [`ALEVEL_PING` / `ALEVEL_TRACEROUTE`], [1], [Network probes from
    the UI],
  [`ALEVEL_HISTORY`], [1], [Viewing object history],
  [`ALEVEL_HISTORY_SEARCH`], [3], [Cross-object history search],
  [`ALEVEL_SHOW_UNALLOCATED_CIDRS`], [3], [Free-block network views],
  [`nets.alevel`, `groups.alevel`], [per-row], [Minimum level to see/use
    a specific net or host group],
)

=== Tier 3: object rights (`user_rights`)

Each row grants one right to one subject:

```sql
type  INT   -- subject kind: 1 = user_groups row, 2 = users row
ref   INT   -- subject id
rtype INT   -- what kind of right (table below)
rref  INT   -- object id (meaning depends on rtype)
rule  CHAR(80) -- mode string, number, or regex (depends on rtype)
```

#table(
  columns: (auto, auto, auto, 1fr),
  table.header([rtype], [Right], [rule], [Semantics]),
  [0], [Group membership], [—], [`rref` = `user_groups.id`; the user
    inherits all of that group's rights (one level, additive).],
  [1], [Server], [`R`/`RW`/`RWS`], [Read / read-write / read-write-super
    on a server and (in privilege mode 0) everything under it.],
  [2], [Zone], [`R`/`RW`/`RWS`], [Same modes scoped to one zone.],
  [3], [Net], [IP range], [Access limited to an address range
    (`$perms{net}` = start/end pairs); writes touching IPs outside all
    granted ranges are rejected.],
  [4], [Hostname mask], [regex], [`rref` = zone id; user may only
    create/edit hosts whose `domain` matches the regex in that zone.],
  [5], [IP mask], [regex], [Regex constraint on IP addresses the user
    may assign.],
  [6], [Authorization level], [0--999], [Contributes to the effective
    ALEVEL (max wins).],
  [7], [Expiration limit], [days], [Maximum host expiration the user may
    set.],
  [8], [Default dept], [text], [Default value for the host `dept`
    field.],
  [9], [Template mask], [regex], [Filters which MX/WKS templates the
    user can select.],
  [10], [Group mask], [regex], [Filters which host groups the user can
    assign.],
  [11], [Delete mask], [regex], [`rref` = zone id; user may only delete
    hosts matching the regex.],
  [12], [Required host field], [field name], [Per-user override of
    `%SAURON_RHF`: `rref = 0` makes the named field mandatory, non-zero
    optional.],
  [13], [Privilege flags], [flag name], [Grants record-type privileges:
    `AREC`, `CNAME`, `SCNAME`, `MX`, `SRV`, `DELEG`, `GLUE`, `DHCP`,
    `PRINTER`, `TLSA`, `TXT`, `RESERV`, … — each gates the corresponding
    "Add X" operation.],
  [14], [Default host], [text], [Default host field values.],
  [100, 101], [Asset mgmt], [—], [Reserved for the asset-management
    extension.],
)

Rights are *additive*: the union of everything granted directly plus
everything inherited from groups, with the most permissive value winning
where they overlap.

=== Loading and checking

`Sauron::BackEnd::get_permissions($uid, \%perms)` loads the whole
picture in one pass (direct rights plus one level of group inheritance):

```perl
%perms = (
  server   => { $serverid => 'RW', ... },
  zone     => { $zoneid   => 'R',  ... },
  net      => { $netid    => [$start, $end], ... },
  hostname => [ [$zoneid, $regex], ... ],   # rtype 4
  delmask  => [ [$zoneid, $regex], ... ],   # rtype 11
  tmplmask => [ $regex, ... ],              # rtype 9
  grpmask  => [ $regex, ... ],              # rtype 10
  flags    => { AREC => 1, MX => 1, ... },  # rtype 13
  rhf      => { dept => 0, ... },           # rtype 12
  alevel   => 5,                            # max rtype 6
  groups   => "group1,group2",
);
```

The legacy CGI checks rights with
`Sauron::CGI::Utils::check_perms($type, $rule, $quiet)`, which reads the
globals set at request start (`%state`, `%perms`) — types include
`level`, `server`, `zone`, `host` (zone RW + hostname mask), `delhost`
(zone RW + delete mask), `ip` (net ranges + IP masks), `flags`, and
`superuser`. It returns *0 for allowed* (shell-style), non-zero with an
error page otherwise. The REST API re-implements the same decision logic
statelessly (its `check_perms` takes explicit arguments and returns
boolean), but *the data model and semantics are identical* — a permission
bug is a divergence between the two implementations.

#note[Privilege mode inheritance.][
  With `$SAURON_PRIVILEGE_MODE = 0` (the default), server-level rights
  imply the same rights on every zone of that server — a user with server
  `RW` needs no per-zone rows. Mode 1 requires explicit zone grants.
  Any API authorization path must honor this fall-through
  (check server rights first, then explicit zone rights).
]

=== Required host fields (RHF)

`%SAURON_RHF` maps informational host fields to 0 (mandatory) or 1
(optional): by default `huser`, `dept`, `location`, `ether`, `duid` are
mandatory; `info`, `asset_id`, `model`, `serial`, `misc`, `email`
optional. Per-user `rtype = 12` rights override individual fields, merged
over the globals at session start. Any create/update path (CGI form or
API) is expected to enforce the merged RHF set — a host API that skips
RHF validation silently weakens site policy.

== The permission lifecycle in practice

A legacy CGI request executes, in order:

+ Load config, connect to DB, verify schema version, check
  `cgi_disabled`.
+ Resolve the session cookie → `load_state` → `%state`
  (uid, sid, auth, superuser, current server/zone).
+ `set_muser($state{user})` for audit stamping.
+ Unless superuser: `get_permissions($uid, \%perms)` and merge RHF
  overrides.
+ Every menu handler action calls `check_perms(...)` before doing
  anything, and superusers short-circuit to "allowed".
+ Mutations call BackEnd, which records history rows tagged with
  `(uid, sid)`.

The REST API mirrors this: authenticate (proxy header, session cookie, or
PAT) → `load_user_context` (which calls `get_permissions` and stashes the
result) → per-route `check_perms` → BackEnd call → `update_history`. The
important invariant: *authorization decisions come from `user_rights` via
`get_permissions`, never from ad-hoc SQL*, so the CGI and API can never
disagree about what a user may do.
