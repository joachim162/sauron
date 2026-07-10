#import "defs.typ": note, warn

= Introduction and Architecture

== What Sauron is

Sauron is a *database-driven configuration management system for DNS and DHCP*.
Instead of administrators editing BIND zone files and `dhcpd.conf` by hand,
all network state — servers, zones, hosts, IP addresses, MAC reservations,
DHCP options — lives in a PostgreSQL database. Interfaces (a legacy Perl CGI
web UI, command-line tools, and the REST API you are building) modify that
database. A separate generator, the `sauron` CLI, transforms the database
contents into flat configuration files that BIND (`named.conf` + zone files)
and ISC dhcpd (`dhcpd.conf`) actually read.

The project originates with Timo Kokkonen (2000--2007), with later
development at the University of West Bohemia and elsewhere (IPv6 support,
DHCPv6, additional features). The codebase is Perl 5, written in a
procedural, pre-modern style: global variables, function prototypes, manual
SQL string building, and CGI.pm HTML generation. Understanding its
conventions — and its sharp edges — is a prerequisite for wrapping it in a
clean REST API.

#note[Why this matters for the API:][
  The REST API is a *bridge*, not a rewrite. It must reuse
  `Sauron::BackEnd` functions rather than issuing raw SQL, so that data
  integrity rules, history logging, and permission semantics stay identical
  to the legacy CGI. Every chapter of this document ends by relating the
  material back to that goal.
]

== The three-tier model

Sauron separates *state*, *interfaces*, and *generation*:

+ *The database (PostgreSQL)* — the single source of truth. Every server,
  zone, host, network, user, and permission is a row. Nothing outside the
  database matters for what will be generated.
+ *The interfaces* — tools that mutate the database: the legacy CGI
  (`cgi/sauron.cgi`), the read-only public browser (`cgi/browser.cgi`),
  \~30 command-line utilities (`addhosts`, `import`, `modhosts`, …), and
  the new REST API. All of them converge on the same Perl module,
  `Sauron::BackEnd`.
+ *The generator (`sauron` CLI)* — reads the database inside one
  `REPEATABLE READ` transaction and writes `named.conf`, zone files,
  `dhcpd.conf`, `dhcpd6.conf`, tinydns data files, and printer
  configuration into a target directory.

Crucially, Sauron *does not need to run on the DNS/DHCP servers
themselves*. The typical deployment is:

- *Management node* — runs PostgreSQL, Apache + CGI (and the REST API),
  and the `sauron` generator (usually from cron or by hand).
- *Service nodes* — run BIND and dhcpd. They only ever receive generated
  text files, pushed by `rsync`/`scp`, followed by a service reload.

== The configuration life cycle

Every change follows the same five steps:

+ *Change* — a user edits a host (new IP, new MAC, new MX record) through
  the CGI, a CLI tool, or the API. The write goes through
  `Sauron::BackEnd`, which stamps modification metadata and records a
  history entry.
+ *Commit* — the change is now durable in PostgreSQL, but *nothing has
  changed in DNS or DHCP yet*. The zone is "pending": its data is newer
  than its last generated serial.
+ *Export* — `sauron --all <servername> <targetdir>` regenerates all
  configuration files for that server. Zone serial numbers are bumped only
  for zones whose data actually changed.
+ *Push* — the generated files are copied to the service nodes.
+ *Reload* — `rndc reload` / dhcpd restart applies them.

This decoupling is a core safety feature: the generator can validate
everything (`--check` runs `named-checkconf`, `named-checkzone`, and
`dhcpd -t` against the output) before anything reaches a production
daemon, and the database keeps a full audit trail (the `history` table) of
who changed what and when.

#warn[Pending changes are invisible to DNS.][
  A REST API consumer creating a host must understand that the record will
  not resolve until the next generator run. The legacy CGI surfaces this as
  the "Show pending" view (zones whose host data is newer than
  `serial_date`); the `check-pending` cron utility emails admins about it.
  The API should expose the same signal.
]

== The domain hierarchy

Everything Sauron manages hangs off a three-level containment hierarchy,
with networks as a parallel grouping structure:

```
servers ──< zones ──< hosts ──< a_entries, mx_entries, txt_entries, ...
   │
   ├──< nets (subnets; auto-assign IP ranges; browser/ACL grouping)
   ├──< vlans (layer-2 groupings; DHCP shared-networks)
   ├──< groups (host groups; shared DHCP/BOOTP/printer settings)
   ├──< root_servers (root hint records for named.ca)
   ├──< keys / acls (TSIG keys, named ACLs)
   └──< vmps (VMPS port/mac management)
```

/ Server: one logical BIND + dhcpd instance — a configuration scope, not
  necessarily a physical machine. Owns all global `named.conf` options
  (paths, ACLs, forwarders, listen addresses, logging), DHCP global
  settings and failover parameters, and SOA defaults inherited by its
  zones. Server names are globally unique.
/ Zone: one DNS zone (`example.com` or `2.168.192.in-addr.arpa`)
  belonging to exactly one server. Carries type (Master/Slave/
  Forward/Hint), the forward/reverse flag, SOA overrides, and per-zone
  BIND ACLs. A zone cannot exist without a server.
/ Host: one *label* within a zone — the richest entity in the model. A
  single host row bundles all DNS record types for that name (A, AAAA,
  CNAME, MX, NS, SRV, TXT, SSHFP, TLSA, …) plus DHCP identity (MAC,
  DUID/IAID) and administrative metadata (user, department, location,
  asset ID). The host's FQDN is `domain` + zone name.
/ Net: an IP network or subnet (CIDR) attached to a server. Used for the
  DHCP subnet map, IP auto-assignment ranges, access control
  (network-level user rights), and navigation in frontends.

The hierarchy also scopes *permissions*: users can be granted rights per
server, per zone, or per network range, with superusers bypassing
everything (see @security).

== Repository map

#table(
  columns: (auto, 1fr),
  table.header([Path], [Contents]),
  [`Sauron/*.pm`], [The core Perl library: `BackEnd.pm` (domain logic,
    4,551 lines), `DB.pm`/`DB-DBI.pm`/`DB-Pg.pm` (database layer),
    `Util.pm` (validation & IP helpers), `UtilZone.pm` / `UtilDhcp.pm`
    (zone-file and dhcpd.conf *parsers*, used by importers), `CGIutil.pm`
    (the CGI form engine), `Sauron.pm` (configuration), `SetupIO.pm`
    (terminal I/O for CLI tools).],
  [`Sauron/CGI/*.pm`], [Legacy web UI menu handlers: `Hosts.pm` (2,343
    lines), `Nets.pm`, `Zones.pm`, `Servers.pm`, `Groups.pm`,
    `Templates.pm`, `ACLs.pm`, `Login.pm`, `Utils.pm` (permission checks
    and shared CGI helpers).],
  [`cgi/`], [`sauron.cgi` — the CGI entry point (dispatch, login, session
    cookies); `browser.cgi` — the anonymous read-only host browser.],
  [`sql/`], [One `.sql` file per table, plus `dbconvert_*` migration
    scripts between schema versions and `DEFAULTS.sql`.],
  [`sauron`], [The generator CLI (3,482 lines) — produces BIND, DHCP,
    DHCPv6, tinydns, and printer configuration from the database.],
  [Repo root scripts], [\~30 admin utilities: `adduser`, `addhosts`,
    `import`, `import-dhcp`, `modhosts`, `expire-hosts`, `runsql`,
    `status`, `modpat`, … (see @clitools).],
  [`sauron_api/`], [The new Mojolicious + OpenAPI REST API (out of scope
    for this document, but the consumer of everything in it).],
  [`frontend/`], [The new web frontend (Vite), a client of the REST API.],
  [`doc/`, `doc/rfc/`], [The original SGML manual and a local archive of
    the DNS/DHCP RFCs.],
  [`test/`], [The canonical "Middle Earth" test dataset: `named.conf`,
    zone files, and `dhcpd.conf` importable via `import` /
    `import-dhcp`.],
  [`knowledge/`], [Markdown knowledge base accumulated during API
    development — worth reading alongside this document.],
  [`config.in`], [Annotated sample of the runtime configuration file
    (`/etc/sauron/config`).],
)

== Development environment notes

Two legacy quirks bite immediately when running anything from a source
checkout:

- *Hardcoded include paths.* Script shebangs read
  `#!/usr/bin/perl -I/opt/sauron` (or `/usr/local/sauron`). In
  development, run scripts as `perl -I. ./script` or export
  `PERL5LIB=$HOME/Documents/sauron`. The `make install` step rewrites
  these paths for production.
- *`DB.pm` is a build artifact.* `Sauron/DB.pm` must be (a symlink to)
  `DB-DBI.pm` — the modern DBI/DBD::Pg implementation. `DB-Pg.pm` is the
  obsolete direct-Pg variant kept for `--with-Pg` builds.

The runtime configuration file `config` is searched in `/etc/sauron/`,
`/usr/local/etc/sauron/`, and `/opt/sauron/etc/`; it is *executable Perl*
evaluated into the `main::` namespace (see @configfile). The minimum
viable settings are `$DB_DSN`, `$DB_USER`, `$DB_PASSWORD`, `$SERVER_ID`,
`$PROG_DIR`, and `$LOG_DIR`. Using `host=localhost` in `$DB_DSN` forces
TCP + password authentication, avoiding PostgreSQL peer-auth mismatches.

To populate a development database:

```sh
perl -I. ./createtables                                  # create schema
perl -I. ./adduser                                       # create superuser
perl -I. ./import --dir=test <servername> test/named.conf   # BIND import
perl -I. ./import-dhcp --server=<servername> test/dhcpd.conf # DHCP import
```
