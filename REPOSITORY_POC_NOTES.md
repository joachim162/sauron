# Repository PoC — Notes

## What this is

Proof-of-concept refactor of `SauronAPI::Controller::Host` so that all
DB/data logic lives in `SauronAPI::Repository::Host`, and the controller
only handles HTTP, authz, and response shape.

The OpenAPI contract is unchanged. The frontend does not need to change.

## Worktree / branch

- Worktree: `../sauron-repository-host`
- Branch:   `feature/repository-host-poc` (off `feature/pagination`)
- Off the existing `feature/pagination` branch so the new
  `HostListResponse` / pagination envelope work is preserved.

## New modules

| Module | Purpose |
|---|---|
| `SauronAPI::Exception` | Base class with `message`, `stringify`, `throw` |
| `SauronAPI::Exception::NotFound` | HTTP 404 |
| `SauronAPI::Exception::Conflict` | HTTP 409 |
| `SauronAPI::Exception::Validation` | HTTP 400 |
| `SauronAPI::Exception::Permission` | HTTP 403 |
| `SauronAPI::Exception::Persistence` | HTTP 500 |
| `SauronAPI::Repository::Host` | All Host CRUD with a clean public API |

## Repository public API

```perl
use SauronAPI::Repository::Host qw(
  host_list host_find host_create host_update host_delete
);

my ($data, $meta) = host_list($server, $zone, page => 1, per_page => 50);
my $host          = host_find($server, $zone, $hostname);
my $host          = host_create($server, $zone, \%input, on_ip => $cb);
my $host          = host_update($server, $zone, $hostname, \%input);
host_delete($server, $zone, $hostname);
```

All functions throw typed exceptions on failure. Inputs and outputs are
clean Perl structures — no marker rows, no header rows, no `marker_count`.

## What moved from controller to repository

- `%FIELDS` codec registry
- `_build_*_record` row builders
- `_build_host_response` (response shape)
- `_validate_type_fields` (type-specific field validation)
- `_copy_host_fields` (scalar field copy)
- All `Sauron::BackEnd` calls for create / update / delete / find
- IP auto-assignment logic
- `db_query` for list endpoint

## What stayed in the controller

- HTTP/auth (`valid_input`, `require_auth`)
- Authz (`check_perms`)
- Required Host Fields (RHF) check
- Exception-to-response mapping (`_render_exception`)
- Server/zone name resolution *for authz purposes only*
- `on_ip` callback closure for IP permission checks
- OpenAPI rendering

## What was NOT changed

- `Sauron::BackEnd` — still has the marker protocol
- `SauronAPI::FieldCodec` / `SauronAPI::Codecs` — still used internally
- `SauronAPI::Controller::Server`, `Zone`, `Net` — untouched
- OpenAPI spec — unchanged
- Frontend — unchanged

## Tests

| Test | Count | Status |
|---|---|---|
| `t/repository_host.t` (new) | 16 subtests | PASS |
| `t/host.t` (existing) | 20 | PASS |
| `t/codec.t` (existing) | 33 | PASS |
| `t/net.t` (existing) | 4 | PASS |

`t/repository_host.t` uses `Test::MockModule` to mock `Sauron::BackEnd`
and `Sauron::DB` so the repository can be tested without a real database.
The mocks are kept alive at file scope (`our @MOCKS`) so the `DESTROY`
on the mock object doesn't auto-unmock mid-test.

## Known caveats / things to revisit

1. **Server/zone resolution duplication** — the controller resolves
   server/zone IDs *for authz* before calling the repository, and the
   repository resolves them again internally. A future cleanup could
   pass these IDs into the repository (or have the repository return
   them as part of its public API).

2. **Authz is still in the controller** — `_check_rhf` and the
   `on_ip` callback both reach into `$c`. This is intentional
   (repository stays HTTP-agnostic) but means the controller still
   has 200 lines, not the ideal "thin controller".

3. **`FieldCodec` still used** — the repository still calls
   `SauronAPI::FieldCodec` to talk to `Sauron::BackEnd`. This is the
   temporary anti-corruption layer discussed in the design review. It
   can be removed when CGI is retired.

4. **Pagination is exact `COUNT(*)`** — same as the current list
   query. No cursor pagination.

5. **No sorting/filtering yet** — `host_list` accepts `page` and
   `per_page` only. The metadata envelope is shaped so sort/filter
   can be added later without changing the contract.

## Running the tests

```bash
# Inside the running container (after syncing):
docker compose restart sauron_api
docker exec sauron-sauron_api-1 bash -c "cd /srv/sauron/sauron_api && prove -l t/host.t t/codec.t t/net.t t/repository_host.t"
```

The unit-only test (no DB):
```bash
docker exec sauron-sauron_api-1 bash -c "cd /srv/sauron/sauron_api && prove -l t/repository_host.t"
```
