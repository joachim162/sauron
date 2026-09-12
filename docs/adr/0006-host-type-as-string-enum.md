# 0006. Host type as a string enum

Date: 2026-08-11
Status: Accepted

## Context

The legacy system represents host record kinds (host, delegation, MX, alias,
reservation, ...) as integer codes: `hosts.type` is an `INT4` column, the CGI
form posts integers, and `BackEnd` keys its type-specific validation on them.
The API initially carried the integers through verbatim: `Host.type`,
`HostListItem.type`, and the `type` field of create/update bodies are
integers.

This forces consumers to consult a dictionary to interpret or produce the
value — the exact anti-pattern flagged in *The Design of Web APIs* (§8.5,
"avoid using non-human-readable codes such as 1 or XYZ"). The upcoming host
search filters (ADR 0007) sharpen the problem: `?type=1` is unguessable, and a
filter's representation must match the data it filters.

Zones already establish the house style: the zone type is the string enum
`M/S/H/F/C/A` everywhere in the API even though the database stores single
characters.

## Decision

The host type is represented as a **string enum** on the wire, everywhere:

```
misc, host, delegation, mx, alias, printer, glue, alias_arec,
srv, dhcp_only, zone, sshfp, tlsa, txt, naptr, caa, reservation
```

- The database and `Sauron::BackEnd` keep integer codes; the slug↔code mapping
  lives in the repository layer (ADR 0001 boundary), including validation
  messages ("Field 'x' is not valid for host type 'mx'").
- `type` accepts/returns these slugs in responses, create/update bodies, and
  the search filter. Unknown slugs → 400.
- Filtering semantics preserved from legacy: `type=host` matches hosts **and**
  reservations (a reservation is a disabled host — see CONTEXT.md); omitted
  `type` means all types.
- Side benefit: `type=misc` becomes filterable for the first time — the legacy
  browse form overloaded code 0 as "Any type", masking real type-0 records.
- The frontend `HOST_TYPES` map is rekeyed by slug and extended with the
  missing types (`sshfp`, `tlsa`, `txt`, `naptr`, `caa`).

## Alternatives considered

- **Keep integers** — zero change, but cryptic (the book's figure 8.12 is
  literally about codes like `1`/`7` for account types), and every new
  consumer hardens the int vocabulary further, raising the cost of this flip.
- **Integer + parallel `typeLabel` field** — the book's escape hatch when codes
  are shared across systems and cannot be replaced. We control both ends, so
  full replacement is possible and cleaner.
- **Accept both spellings** — ambiguous, rejected.
