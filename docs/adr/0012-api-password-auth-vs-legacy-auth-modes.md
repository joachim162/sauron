# 0012. API password authentication vs legacy authentication modes

## Context

The legacy CGI changes its password behaviour based on `$SAURON_AUTH_MODE`
(`cgi/sauron.cgi:194`, `:265-287`) and `$SAURON_AUTH_PROG`
(`cgi/sauron.cgi:685-687`, `Sauron/CGI/Login.pm` `passwd` branch). The REST
API has its own stack (password, proxy, PAT) governed by `auth.mode`
(`password | oidc | both`). The API process loads the legacy config, but no
API code reads `$SAURON_AUTH_MODE` or `$SAURON_AUTH_PROG`.

## Decision

The API's password behaviour follows only its own `auth.mode` and the
`users.password` hash:

- `POST /auth/login` verifies against the database hash.
- `POST /auth/me/password` works when `auth.mode` is `password` or `both`,
  otherwise it returns 403. Accounts without a local password get 409.
- The API never executes external authentication programs.

## Accepted divergences from legacy

| Configuration | Legacy CGI | REST API |
|---|---|---|
| `SAURON_AUTH_PROG` set | Password change refused; login checked by the external program | Login and change keep using the database hash |
| `SAURON_AUTH_MODE=1` | "Change password" hidden, handler not blocked | Change refused (403) when `auth.mode` is `oidc` |
| Proxy-authenticated user, `password` deployment | Not applicable | Change allowed; updates the hash that proxy login does not use |

## Consequences

- Operators who set `$SAURON_AUTH_PROG` for the CGI must treat the API
  password stack as separate; the two interfaces can disagree about which
  credential is authoritative.
- Clients should read `auth.mode` from `GET /auth/config` before showing the
  password form.
- Changing this behaviour requires a new ADR that supersedes this one.
