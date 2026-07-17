# 0001. Introduce SauronAPI::Repository layer

Date: 2026-07-17
Status: Accepted

## Context

Sauron has two consumers of the same database: the legacy CGI interface and
the Mojolicious REST API. Both historically call `Sauron::BackEnd`, a
4,500-line module whose function signatures and marker-array return formats
are frozen by CGI callers.

The API needs paginated list endpoints, with sorting and filtering planned
next. That requires dynamically built SQL (`LIMIT`/`OFFSET` now, dynamic
`WHERE`/`ORDER BY` later), which does not fit `Sauron::BackEnd`:

- Adding pagination parameters to existing functions would change signatures
  that CGI depends on.
- Writing new `*_paginated` functions would duplicate the WHERE/ORDER BY
  logic of the existing ones inside the legacy file, where the two copies
  can drift.
- Building SQL in controllers was rejected: it mixes DB logic into the HTTP
  layer, and the project rule has been "all database operations go through
  `Sauron::BackEnd`".

Meanwhile the API controllers had grown to contain codec registries,
marker-format translation, validation, and response shaping — all of which
is data logic, not HTTP logic.

## Decision

Introduce a repository layer: `SauronAPI::Repository::<Object>` modules that
own all database access for one API resource. First implementation:
`SauronAPI::Repository::Host`.

The rules of the layer:

- **Reads**: repositories build and execute their own SQL via
  `Sauron::DB::db_query`. Values are always bound parameters (`db_query`
  already supports `@bind_vals`); identifiers (future sort/filter columns)
  come from hardcoded per-repository whitelist maps. No user input ever
  becomes SQL text.
- **Writes**: repositories delegate to `Sauron::BackEnd`, which encodes real
  write logic in its marker protocol. `SauronAPI::FieldCodec` stays inside
  the repository as a temporary anti-corruption layer.
- **Hard boundary**: once a resource has a repository, controllers must not
  call `Sauron::BackEnd` or `Sauron::DB` for that resource. All DB contact
  flows through the repository.
- **Name resolution**: controllers resolve server/zone names to IDs (needed
  for authorization anyway) and pass IDs to the repository. A shared
  `get_zone_id_or_404` helper mirrors the existing `get_server_id_or_404`.
- **Errors**: repositories throw a single `SauronAPI::Exception` class with
  `status`, `kind`, and `message` attributes; controllers map exceptions to
  HTTP responses in one place. BackEnd's numeric return codes never leak
  past the repository.
- Controllers keep only: HTTP/OpenAPI validation, authentication,
  authorization (`check_perms`, required host fields), name resolution, and
  exception-to-response mapping.

## Alternatives considered

- **New `*_paginated` functions in `Sauron::BackEnd`** — rejected. Dynamic
  query building fights the module's CGI-frozen signatures and duplicates
  WHERE-clause logic between old and new functions.
- **SQL in controllers** — rejected. Mixes DB logic into the HTTP layer.
- **Five exception subclasses (`Exception::NotFound`, `Exception::Conflict`,
  ...)** — rejected in favor of one class with attributes. The controller
  maps on `status`/`kind` and never dispatches on class; subclasses added
  files without behavior.
- **Result objects instead of exceptions** — rejected. Forgetting an
  `unless $r->{ok}` check silently propagates failure as success; exceptions
  keep the happy path clean and unwind from deep BackEnd calls naturally.

## Consequences

- List-query logic temporarily exists in two worlds: CGI's `get_*_list` in
  `Sauron::BackEnd` and the API's `*_list` in repositories. This duplication
  is intentional and bounded.
- `AGENTS.md` is amended: repositories are the API's data-access layer for
  reads; `Sauron::BackEnd` remains mandatory for writes and for all CGI use.
- When the legacy CGI is retired, the repository modules fold into the
  successor of `Sauron::BackEnd`, `FieldCodec` and the marker protocol are
  deleted, and the duplication ends. Controllers require no changes at that
  cutover — that is the payoff of the hard boundary.
- Net, Zone, and Server repositories follow the same pattern as their
  endpoints gain pagination. A shared query-builder helper may be extracted
  from the second or third repository, not before.
