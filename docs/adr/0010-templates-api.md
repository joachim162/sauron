# 0010. Templates API

Date: 2026-10-01
Status: Accepted

## Context

Four legacy resources are managed under the CGI **Templates** menu
(`Sauron/CGI/Templates.pm`) but were absent from the REST API (umbrella
joachim162/sauron#31). They share a menu and an authorization story but
differ in scope, shape, and consumer:

- **MX template** — zone-scoped (`mx_templates.zone`); a reusable set of MX
  entries. A host may point at one (`hosts.mx`) or carry its own `mx_l`.
- **WKS template** — server-scoped (`wks_templates.server`); a reusable set
  of WKS entries. A host may point at one (`hosts.wks`) or carry its own.
- **Printer class** — global (`printer_classes`); a printcap class library.
  Nothing references it by id.
- **HINFO template** — global (`hinfo_templates`); a canned HINFO value
  (hardware/software) offered as a suggestion in host forms. Hosts store
  HINFO as free text, not by reference.

The MX/WKS tables have **no uniqueness** on `(scope, name)` (unlike every
other named scoped table — issue joachim162/sauron#47), and no code path
resolves a template by name (`get_mx_template_by_name` is dead). Template
`name` is therefore a human-facing label, not an identity. The two form
type-check regexes (`printer_class`, `hinfo`) live only in the CGI
(`Sauron::CGIutil::form_check_field`) and are unenforced server-side
(joachim162/sauron#46).

## Decision

**Placement and identity (id-addressed).** Scoped kinds nest under their
owner; global kinds are root collections. Every singleton is
`collection/{id}`:

| Kind | Collection | Item |
|---|---|---|
| MX | `GET/POST /servers/{server}/zones/{zone}/mx-templates` | `…/mx-templates/{id}` |
| WKS | `GET/POST /servers/{server}/wks-templates` | `…/wks-templates/{id}` |
| Printer | `GET/POST /printer-classes` | `/printer-classes/{id}` |
| HINFO | `GET/POST /hinfo-templates` | `/hinfo-templates/{id}` |

Singletons are addressed by numeric **id**, not name. Names are labels and
may collide (see #47) and are unconstrained (MX/WKS) or `/`-bearing (HINFO),
so name-in-path would be ambiguous and URL-hostile. Id-addressing sidesteps
the missing uniqueness entirely; the API does not depend on #47. Nested
singletons validate that the template belongs to the path's `{zone}`/`{server}`
(404 otherwise), mirroring the host endpoints.

**Two response shapes, per kind.** Lists return summaries; singletons return
the full object. Per kind the detail adds the child entry array and (MX/WKS)
`host_count`; entry arrays are never on list items. The existing
`mx_l`/`wks_l`/`printer_l` entry schemas (already used by the host API) are
reused rather than re-declared. Audit fields (`cdate_str`, `mdate_str`,
`cuser`, `muser`) appear on the summary and are nullable; `expiration` is
omitted (unused by every template form). No `kind` discriminator — the path
determines the kind, avoiding a polymorphic schema.

**Writes.** `POST` requires `name` (MX/WKS/PRINTER) or `hinfo` (HINFO);
`comment`, `alevel` (MX/WKS, default 0), and the entry array (default `[]`)
are optional. HINFO injects legacy `addhinfo` defaults (`type = hardware`,
`pri = 100`). `PUT` is a partial update with replace-all array semantics
(VLAN precedent, ADR 0009); `name` is mutable, which is safe because
singletons are id-addressed. No defaults are invented beyond the above.

**Delete.** MX/WKS `DELETE …/{id}?reassign_to=<id>`: `reassign_to` is
optional, and omitting it detaches referencing hosts (`mx`/`wks = -1`),
matching the legacy default. A supplied target must exist, be in the same
zone (MX) / server (WKS), and differ from the deleted template. This mirrors
the legacy Delete prompt and the `group_delete` transaction shape
(reassign-first, then the BackEnd delete under
`db_ignore_begin_and_commit`). PRINTER/HINFO delete takes no parameter.
Response is `204`.

**Authorization (legacy parity, `Sauron/CGI/Templates.pm` + `chk_perms`).**

| Kind | Read | Write |
|---|---|---|
| MX | `server: R` on the path's server | `tmplmask`(name), deny-by-default |
| WKS | `server: R` on the path's server | superuser |
| Printer | any authenticated user | superuser |
| HINFO | any authenticated user | superuser |

`alevel` is an **assignment** filter, not a management gate. A new
`check_perms(type => 'tmplmask', name => …)` is added to `AuthZ.pm`,
deny-by-default, matching `chk_perms` (and the `grpmask` precedent).
PC/HINFO are global and root-level, so the legacy `server: R` gate has no
endpoint equivalent; reads require only authentication
(joachim162/sauron#48).

**Pickers.** The host-form pickers are dedicated bare-array endpoints —
`/servers/{server}/zones/{zone}/assignable-mx-templates` and
`/servers/{server}/assignable-wks-templates` — filtered by the caller's
`alevel` ceiling, mirroring `assignable-groups`/`assignable-subnets`
(ADR 0008). The management lists are never alevel-filtered (legacy shows
all). HINFO's global list doubles as its picker; printer classes have no
picker. The alevel ceiling remains picker-only (legacy never enforced it on
host writes); hardening host writes is deferred (joachim162/sauron#51).

**Validation.** Enforce the two CGI form regexes (`printer_class`, `hinfo`)
in the repository (joachim162/sauron#46); do not enforce name/value length
caps (the legacy server never did — VLAN precedent); do not enforce MX/WKS
name uniqueness (id-addressed; the schema fix is #47, the clean `409` is
#50). Required subfields are enforced; note the WKS-template quirk that
`services` may be empty. All rules are pinned by parity tests
(joachim162/sauron#49).

**Lists.** `{data, metadata}` envelope with sort (default `name`; HINFO
`type`,`pri`,`hinfo`) and filters: `name`/`comment` (regex), HINFO `hinfo`
(regex) and `type` (enum), MX/WKS `alevel` (int). Unknown params → 400.

**Host endpoints unchanged.** This resource is additive; `mx`/`wks`,
`mx_rec`/`wks_rec`, and `mx_l`/`wks_l` on hosts are untouched.

**Code organization.** Four controllers (one per kind/path family) plus a
single shared `SauronAPI::Repository::Template` holding the kind-aware
CRUD/entry-array/envelope logic.

## Alternatives considered

- **One polymorphic `/templates` collection with a `kind` discriminator** —
  one tag, one page, but four structurally divergent kinds, heavy `oneOf`
  (no precedent in this API), and per-kind authz/scope; rejected in favour of
  four resources.
- **Name-addressed singletons** (`…/{name}`) — matches Hosts/Zones/Nets/VLAN,
  but requires scoped uniqueness the schema lacks (#47) and is URL-hostile
  for HINFO (`/` allowed by the form) and free-text MX/WKS names; rejected.
- **Root-level `/mx-templates/{id}` split from the nested collection** — no
  redundant scope, but the item path diverges from its collection and
  authz scope must be re-derived from the row; rejected for the conventional
  `collection/{id}`.
- **Bake the alevel ceiling into the management list** — hides higher-level
  templates from managers who may edit them; rejected.
- **Add a shared `alevel` column to `printer_classes`/`hinfo_templates`** —
  would let all kinds share the ceiling, but the CGI is frozen, printer
  classes have no enforcement point, and it is a new capability rather than
  parity; rejected (see #48/#51).
- **Enforce MX/WKS name uniqueness in the repository now** — racy and differs
  from both current legacy and the post-#47 state; deferred to #47/#50.
- **Change host endpoints to embed template objects** — out of scope;
  additive resource only.

## Consequences

- New public resources `/servers/{server}/zones/{zone}/mx-templates`,
  `/servers/{server}/wks-templates`, `/printer-classes`, `/hinfo-templates`,
  their per-kind schemas, the `assignable-*` pickers, list filter/sort
  params, four controllers, and one shared Template repository.
- `AuthZ.pm` gains a deny-by-default `tmplmask` check.
- The host-form pickers have a real data source; host endpoints and the
  legacy CGI are unchanged.
- Known debt:
  - joachim162/sauron#46 — CGI-only validation regexes (`printer_class`,
    `hinfo`); API must enforce.
  - joachim162/sauron#47 — `mx_templates`/`wks_templates` lack scoped
    uniqueness (schema bug); the API does not depend on the fix.
  - joachim162/sauron#48 — global printer-class/HINFO read authz has no
    legacy `server: R` equivalent.
  - joachim162/sauron#49 — validation-parity tests.
  - joachim162/sauron#50 — map MX/WKS duplicate-name unique violation to
    `409` once #47 lands. (printer_classes.name and hinfo_templates.hinfo
    are UNIQUE in the schema today, so their duplicates map to `409`
    already — VLAN/Group `_assert_unique_name` precedent.)
  - joachim162/sauron#51 — alevel ceiling is picker-only; host-write
    enforcement deferred.
  - `doc/reference-src/ch4-security.typ` describes `tmplmask` (rtype 9) as
    filtering which MX/WKS templates a user can *select*; the code applies it
    to MX *management* only and selection is alevel-based (doc/code mismatch,
    not addressed here).
  - Frontend Templates pages (MX/WKS/PRINTER/HINFO) and host-form pickers are
    a follow-up slice (joachim162/sauron#52).
