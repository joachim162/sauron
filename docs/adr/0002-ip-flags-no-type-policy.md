# 0002. IP reverse/forward flags are type-agnostic generation toggles

Date: 2026-07-21
Status: Accepted

## Context

The `a_entries` table stores per-IP `reverse` (PTR record) and `forward`
(A record) boolean flags. The REST API historically returned `ips` as a
plain string array, dropping the flags entirely, and hardcoded `t,t` on
create for every host type.

The legacy CGI applies a per-type flag policy at form level: types 1, 6
and 101 are created with `t,t`, type 9 (DHCP-only) is forced to `f,f` and
its edit form shows no flag controls. The question was whether the API
should replicate this policy.

Investigation of the layers below the CGI showed no constraint anywhere:

- The DB columns are plain `BOOL DEFAULT true` with no CHECK constraints
  and no link to host type.
- `Sauron::BackEnd::add_host`/`update_host` pass the marker rows verbatim
  to `add_array_field`/`update_array_field` — no validation or coercion.
- The zone generator (`sauron` script) consumes the flags as pure
  generation toggles and applies its own host-type filters on top: A
  records only for type 1 (`a.forward=true`), PTR only for types 1/6/10
  (`a.reverse=true`), glue A records for type 6 regardless of the forward
  flag. Flags on any other type are inert.

The CGI policy is therefore UI cosmetics, not a data-model rule.

## Decision

- `ips` in the detail GET response and in create/update request bodies
  becomes an array of objects `{ip, reverse, forward}` with JSON
  booleans. This is a breaking change to the pre-release API; the
  frontend is the only consumer. The list endpoint keeps `ips` as a
  plain string array (lightweight projection).
- Any flag combination is accepted on any host type — the API performs
  no per-type flag validation. The CGI's per-type forcing is deliberately
  not replicated.
- Omitted flags default to `true`/`true` for all types, matching the DB
  column defaults.
- Both flags false is accepted (a tracked-but-unpublished address is a
  legitimate state and exists in production data).
- Request bodies accept objects only; no plain-string shorthand.

## Alternatives considered

- **Mirror the CGI policy (f/f for type 9, reject or coerce explicit
  true flags)** — rejected. There is no backend constraint to enforce;
  the generator never emits records for type 9 regardless of flag
  values, so the policy would guard nothing.
- **Keep `ips` as strings and add a parallel `ip_entries` object
  field** — rejected. Two fields describing the same data can disagree,
  and every consumer must learn which one wins on write.
- **Polymorphic items (string or object)** — rejected. Fuzzy schema,
  messier validation, two permanent ways to say the same thing.

## Consequences

- Clients updating a host's flags send the full desired `ips` set
  (array fields keep replace-all semantics).
- A host created via the API with type 9 carries `t,t` flags by default
  whereas the CGI creates `f,f`. Both are semantically identical because
  the zone generator never emits records for type 9.
- `a_entries.comment` remains unexposed by the API; adding it is a
  separate change if ever needed.
