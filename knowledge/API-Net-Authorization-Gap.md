# API Net Authorization Model
#authorization #net #api #sauron-core

The REST API net endpoints now follow the legacy CGI authorization model:
network object management is superuser-only, while listing and reading
networks require server `R` access and are filtered by the user’s
authorization level.

## Legacy CGI Behavior

`Sauron/CGI/Nets.pm` gates network operations as follows:

- **Browse/list:** requires `check_perms('server','R')` and only shows nets
  whose `alevel <= $perms->{alevel}`.
- **Create/update/delete:** requires `check_perms('superuser')`.
- **Net-level rights (`rtype=3`):** are **not** used for net object access.
  They are only used by `Sauron/CGI/Hosts.pm` (`check_perms('ip', ...)`)
  to validate whether a user may assign a host to a given IP/network range.

`Sauron/CGI/Utils.pm` only applies `SAURON_PRIVILEGE_MODE` inheritance for
`zone` checks, not for networks.

## API Implementation

`sauron_api/lib/SauronAPI/Controller/Net.pm`:

| Endpoint | Required permission |
|----------|---------------------|
| `GET /servers/{server}/networks` | server `R`; list filtered by `user_alevel` |
| `GET /servers/{server}/network/{net}` | server `R` |
| `POST /servers/{server}/networks` | superuser |
| `PUT /servers/{server}/network/{net}` | superuser |
| `DELETE /servers/{server}/network/{net}` | superuser |

`sauron_api/lib/SauronAPI/AuthZ.pm` no longer has a `type => 'net'` branch,
`has_net_access()`, or `filter_nets()`. Net object authorization is handled
with the standard `server` and `superuser` checks above.

## Historical Gap

Previously the API treated nets like zones: in privilege mode `0`, server `RW`
was inherited as net `RW`, and net-level rights were all-or-nothing because
`BackEnd::get_permissions()` stored only the IP range, not the rule string.
This diverged from the legacy CGI and was fixed to match it.

- GitHub issue: [#10](https://github.com/joachim162/sauron/issues/10)

## Related

- [[Sauron-Core-Authorization-System]] — Legacy permission model and `rtype` mapping
- [[Authentication-and-Authorization]] — How the API loads and checks permissions
- [[Sauron-Core-Security-Model]] — Broader security overview
