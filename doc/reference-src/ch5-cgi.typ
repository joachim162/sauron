#import "defs.typ": note, warn

= The Legacy CGI <cgi>

The legacy web interface is the behavioral specification the REST API and
new frontend must match. It consists of one dispatcher script
(`cgi/sauron.cgi`), eight menu-handler modules (`Sauron/CGI/*.pm`), a
declarative form engine (`Sauron::CGIutil`), and a separate anonymous
browser (`cgi/browser.cgi`).

== Request lifecycle in `sauron.cgi`

Every request — there is no routing beyond query parameters — flows
through the same script:

+ *Bootstrap.* `load_config()`, log-path sanity checks, `db_connect2()`,
  schema-version check, `cgi_disabled()` maintenance flag.
+ *Session.* Read the `sauron-$SERVER_ID` cookie (32 hex chars). If
  present, `fix_utmp` reaps stale sessions and `load_state` inflates
  `%state` from the `utmp` row. If absent or invalid, a new cookie is
  minted and the login form is shown.
+ *Login.* `login_auth()` implements the mode-0 form login (or trusts
  `REMOTE_USER` in mode 1): validates input, `get_user`, `pwd_check`
  (or external program), checks account expiration, then populates
  `%state` (uid, sid via `new_sid`, auth = yes, superuser flag, default
  server/zone) and writes lastlog/history. Idle sessions
  (`$SAURON_USER_TIMEOUT`) and IP-mismatched cookies are rejected.
+ *Context.* `$server`, `$serverid`, `$zone`, `$zoneid` come from
  `%state` — the CGI is *modal*: you first "select" a server and zone,
  then all host operations implicitly target them.
  `cgi_util_set_zone/server` publish them to the form engine;
  `set_muser` stamps the audit identity.
+ *Permissions.* Non-superusers get `get_permissions` + RHF merge
  (see @security).
+ *Dispatch.* The `menu` query parameter selects a module from
  `%menus`:

```perl
%menus = (
  'servers'   => 'Sauron::CGI::Servers',
  'zones'     => 'Sauron::CGI::Zones',
  'hosts'     => 'Sauron::CGI::Hosts',
  'nets'      => 'Sauron::CGI::Nets',
  'groups'    => 'Sauron::CGI::Groups',
  'templates' => 'Sauron::CGI::Templates',
  'acls'      => 'Sauron::CGI::ACLs',
  'login'     => 'Sauron::CGI::Login',
);
```

  The module is `require`d lazily and its single entry point invoked as
  `Module::menu_handler(\%state, \%perms)`. The `sub` parameter selects
  the action within the module (`sub=add`, `sub=edit`, `sub=del`, …),
  and the left-hand menu (`%menuhash`) is just a list of links with
  visibility rules — `'root'` (superuser only), `['level', N]`
  (ALEVEL gate), `['flags', 'MX']` (privilege flag), `['zone', 'RW']`
  (object right).
+ *Plugins.* `$SAURON_PLUGINS` names modules under `plugins/`; each
  contributes menu items and hooks that *override* a `(menu, sub)` pair,
  dispatching to `Sauron::Plugins::<Name>` instead — the extension
  mechanism for site-local features.

Output is 1990s-style HTML printed directly with CGI.pm helpers (frames
optional via `/frames` path info). A `csv` parameter switches search
results to `text/csv` download.

== Menu handlers

Each `Sauron::CGI::*` module is one long `menu_handler` with an
if/elsif chain on `$sub`. What they cover:

#table(
  columns: (auto, 1fr),
  table.header([Module], [Actions]),
  [`Hosts.pm`], [The big one (2,343 lines): host search/browse (with
    saved search state in utmp), add (per type — the `type` query
    parameter drives which form appears), edit, delete (with
    confirmation), move between zones/nets, copy, renumber IPs, show
    history, ping/traceroute. Enforces hostname masks, delete masks,
    RHF, IP-range rights, privilege flags, TTL clamps, and the
    ether/duid uniqueness conflicts.],
  [`Zones.pm`], [Zone list, select current zone, add (auto-creating the
    apex host), edit (SOA fields + array fields), copy, delete, "Add
    Default Zones" (loopback + root hints), and the *pending* view —
    zones whose newest host `mdate`/`rdate` exceeds `serial_date`.],
  [`Servers.pm`], [Server select/add/edit/delete — superuser territory;
    edits cover all the named.conf/DHCP option groups from
    @database.],
  [`Nets.pm`], [Network/subnet/virtual-subnet CRUD, list modes
    (networks / + subnets / + all / + free blocks), VLAN and VMPS
    management, auto-assign range configuration.],
  [`Groups.pm`], [Host group CRUD and membership-aware deletes.],
  [`Templates.pm`], [MX/WKS/HINFO templates and printer classes.],
  [`ACLs.pm`], [Named BIND ACLs and TSIG keys (ALEVEL-gated).],
  [`Login.pm`], [User info page (shows effective rights), who-is-online
    (utmp), MOTD, password change, per-user defaults (save current
    server/zone), lastlog and history search (gated), add news.],
  [`Utils.pm`], [Shared helpers: `check_perms` (the CGI-side
    authorization engine), pickers/selectors, ping/traceroute
    wrappers.],
)

== The form engine (`Sauron::CGIutil`)

The CGI never hand-writes forms. Each entity has a *form definition* — a
Perl data structure listing fields with type, label, and constraints —
interpreted by two functions:

- `form_magic($prefix, \%data, \%form)` — renders the form: text fields,
  enums (`form_field_enum`), textareas, list-editing widgets for array
  fields (add/delete row buttons operating on the marker-row format
  directly), and MX/WKS-template pickers. It also *reads submitted
  values back* into the data hash.
- `form_check_form($prefix, \%data, \%form)` /
  `form_check_field` — validation pass: type checks (domain name, IP,
  CIDR, MAC, integer ranges), mandatory-vs-optional driven by the field's
  `empty` attribute (wired to `%SAURON_RHF` for host metadata), plus
  regex-based `chr_check_field` character whitelists
  (`valid_safe_string`).

`display_form` renders a read-only view of the same definition;
`display_list` renders tabular listings; `display_dialog` is the
confirm-dialog helper. This declarative layer is why the marker-row array
format (@arrayfields) permeates everything: form widgets edit those
arrays in place and hand them straight to `update_*`.

For the API this engine is *replaced* by OpenAPI schema validation — but
the semantic rules embedded in the form definitions (which fields exist
per host type, which are mandatory, what validates as a hostname or MAC)
are the compatibility contract. When in doubt about a field's rules, the
form definition in the relevant `Sauron/CGI/*.pm` is the ground truth.

== `browser.cgi` — the anonymous browser

A separate, read-only CGI with its own config (`config-browser`) and *no
authentication*: it lets anyone on the intranet search hosts and browse
networks. Its safety rails are configuration, not permissions:
`BROWSER_SHOW_FIELDS` / `BROWSER_HIDE_FIELDS` control which host columns
appear, `BROWSER_HIDE_PRIVATE` hides nets flagged private (`type` bit
0x01), and `BROWSER_MAX` caps result counts. It reads the database with
the same BackEnd calls. Functionally it corresponds to a future
unauthenticated/read-only slice of the REST API — worth remembering that
"public read access to host inventory" is an existing, sanctioned use
case with field-level filtering requirements.

== What the API must replicate (and what it must not)

*Replicate:*
- The permission checks at every action, including masks, flags, RHF,
  net ranges, and privilege-mode fall-through.
- History logging (`update_history`) for every mutation, with a
  meaningful action string.
- Uniqueness-conflict handling for `domain`, `ether`, `asset_id`, DUID,
  and IPs (constraint violations → 409, not 500).
- The modal server/zone scoping — as explicit URL hierarchy
  (`/servers/{s}/zones/{z}/hosts/{h}`) rather than session state.
- TTL clamping (`$TTL_MIN_SEC`..`$TTL_MAX_SEC`) and hostname validation
  levels.

*Do not replicate:*
- utmp-style server-side UI state (searches, current selections) — that
  is presentation state and belongs in the frontend.
- HTML-embedded conveniences (the `'MANUAL'` sentinel in subnet
  dropdowns, suggestion `<select>` markup from `get_ip_sugg`) — expose
  the underlying data (nets, suggested IPs) as JSON and let the client
  render.
- The `S:`/`H:` overloaded string errors — translate to structured HTTP
  errors at the boundary.
