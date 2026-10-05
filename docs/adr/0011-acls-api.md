# 0011. ACLs API

Date: 2026-10-02
Status: Accepted

## Context

An **ACL** (see CONTEXT.md) is a named, server-scoped, reusable match list
consumed by server and zone options (`allow_transfer`, `allow_query`,
`allow_recursion`, …). Those AML fields are **already exposed** by the
Server and Zone repositories through the `aml()` codec — but their `mode=1`
elements carry bare ACL ids with no endpoint able to list, create, or delete
the referenced objects (umbrella joachim162/sauron#31, after Groups and
Templates). **TSIG keys** are the sibling: the `mode=2` elements' target,
browse-only in the legacy CGI (`Sauron/CGI/ACLs.pm::browse_keys`); their
lifecycle lives in the `keygen` CLI (master-key RC5 crypto, external
`tsig-keygen`), deliberately outside the web layer.

The legacy contract (`Sauron/CGI/ACLs.pm`, `%acl_form`, the ftype-12 AML
machinery in `Sauron/CGIutil.pm`):

- ACLs: `id, server, name, type, comment` + members in `cidr_entries`
  (`type=0, ref=acl id`). Four global built-ins at `server = -1`:
  `any, none, localhost, localnets` — non-clickable, non-editable,
  non-deletable. Schema `UNIQUE(name, server)`.
- Name: required, texthandle `[A-Za-z0-9_.-]+`, whitespace stripped;
  `len=25` is client-side `maxlength` only. Comment: optional, whitespace
  `'P'` (preserved). No server-side length caps (VLAN ADR precedent).
- Members (AML save rules, `CGIutil.pm` ~616–650):
  `mode` int required; `ip` `is_cidr`-validated when non-empty
  (`empty=1`); `acl`/`tkey`/`op` required ints (`empty=0`); `comment`
  free text. The *Add* buttons silently drop rows missing their value.
  Acyclicity of nested ACLs is enforced by masking the reference picker to
  ids lower than the ACL being edited (`get_acl_list(..., mask)`,
  `acl_mode==1`).
- Authorization: everything passes `check_perms('server','R')`; browsing
  requires `level >= ALEVEL_ACLS` (=5); Add/Edit/Delete require superuser.
- Delete: counts `cidr_entries WHERE acl=id`, prompts for a replacement,
  then `delete_acl` deletes the member rows (`type=0, ref=id`) and
  reassigns referencing rows — but only `type>0` ones, leaving nested
  references dangling (joachim162/sauron#53).

## Decision

**Placement and identity.** `/servers/{server}/acls` and
`/servers/{server}/acls/{acl}`; `{acl}` is the **name**, resolved by a
`get_acl_id_or_404` helper via `BackEnd::get_acl_by_name` (exact-server
matching — consistent with zone/group/vlan conventions; ACLs have scoped
uniqueness, so this is safe where templates were not). Parameter carries
`x-mojo-placeholder: '#'`. Singletons resolve **server-owned rows only**;
built-ins appear in the collection (with ids/names for pickers) but a
built-in name in a singleton path is a 404, mirroring legacy's
non-clickable "(Built-in)" rows and making built-ins immutable/deletable
by construction.

**Response shapes.** `AmlElement` becomes a shared schema component:
`mode, ip (nullable), acl (nullable), tkey (nullable), op, comment
(nullable)` — defensive nullability because decode passes DB values
through and legacy rows predate the `''` coercion of `build_aml_record`.
`AclSummary` (list): `id`, `server_id`, `name`, `comment` (nullable),
`builtin` (JSON boolean, `true` iff `server_id = -1`), nullable audit
fields `cdate_str`/`mdate_str`/`cuser`/`muser`. `Acl` (detail): summary +
`acl` (member array, named after the legacy tag/codec key) + `ref_count`
(`COUNT(cidr_entries WHERE acl=id)` — the number the legacy delete prompt
shows). The reserved `type` column is omitted.

**Lists.** Standard `{data, metadata}` envelope containing server ACLs
**and** built-ins in one query. Filters `name`/`comment` (regex), unknown
params → 400; sorts `name` (default), `comment`.

**Writes.** POST: `name` required (handle regex; stored verbatim — no
lowercasing, VLAN/#43 precedent), `comment` optional nullable, `acl`
optional default `[]`. PUT: partial; `name` mutable (rename changes the
URL; handle-invalid → 400, `(name, server)` conflict → 409); `acl` is
replace-all with order preserved (VLAN precedent). Member validation in
the repository (strict improvement over the silent-drop/D-B-error legacy
behaviour), via `SauronAPI::Exception::validation` (400):

- `mode` ∉ {0,1,2} → 400.
- `mode=0`: `ip` required and `is_cidr`-valid (`Sauron::Util`, the same
  helper the CGI's `cidr` check uses); the Postgres `CIDR` cast stays the
  backstop/normalizer.
- `mode=1`: `acl` required > 0, resolving to a server-owned ACL or a
  built-in; on PUT, referenced ids must be **lower than the edited ACL's
  id** (self-reference and cycle prevention — the API encoding of the
  legacy picker mask). On POST any in-scope id is valid (new ids are
  always highest).
- `mode=2`: `tkey` required > 0, existing server key (`type=1,
  ref=server`) via `BackEnd::get_key`.
- `op` ∈ {0,1}; fields inapplicable to the mode are normalized to NULL,
  not rejected (the legacy form hid those inputs rather than erroring).
- No de-duplication (legacy has none).

**Delete.** `DELETE …/{acl}?reassign_to=<id>` → 204. Omitting
`reassign_to` detaches (`acl=-1`); supplying one validates existence
(server-owned or built-in) and difference from the deleted ACL.
**Corrected transaction:** the repo reassigns/detaches **all** rows with
`acl=id` — including `type=0` nested references left dangling by
`BackEnd::delete_acl` (joachim162/sauron#53) — wrapping the BackEnd call
per the templates/group precedent; BackEnd untouched.

**Authorization (legacy parity).** Reads: `server R` **and**
`level >= ALEVEL_ACLS` (superuser bypasses). Writes: `superuser`.
Consequence: zone editors (RW, level < 5) keep ACL **ids** in zone AML
payloads but cannot resolve names through the API — legacy leaks the names
only incidentally via the zone form's ACL popup. Deliberately not loosened
to `server R`; the gap is the already-tracked picker-authz class
(joachim162/sauron#42).

**Keys (read-only companion).** `GET /servers/{server}/keys` → envelope;
items `id`, `name`, `algorithm` (int), `keysize`, `mode` (int), `comment`
(nullable), `cdate_str`/`mdate_str` (nullable); filters `name`/`comment`
(regex), sort `name` (default); authz `server R` + `level >= ALEVEL_ACLS`
(= legacy `browse_keys`). No singleton, no writes, never `secretkey`/
`publickey` — lifecycle stays in `keygen` pending a separate security
design.

**Frontend.** One sidebar ACLs menu with sub-items **ACLs** and **Keys**
(mirroring the CGI; Templates-menu mechanics). Routes `/acls`,
`/acls/keys`; the existing `/keys` redirects. ACL list (builtin badges,
non-clickable built-ins, create dialog), ACL detail (name/comment edit,
ordered member editor with mode selector — CIDR field / ACL dropdown
sourced from the same list / Key dropdown from the keys list — NOT
toggle, comment; delete dialog shows `ref_count` and the reassign
select superuser-gated actions), read-only Keys table. Server/zone AML
pickers stay out of scope (server/zone forms have no AML editing yet).

**Code organization.** `Controller/Acl.pm` + `Controller/Key.pm`;
`Repository/Acl.pm` + `Repository/Key.pm`; `get_acl_id_or_404` helper in
`SauronAPI.pm`; `acls.yaml`/`acl.yaml`/`keys.yaml` path files;
controller-parity suite `t/acl.t` (with keys coverage).

## Alternatives considered

- **Id-addressed singletons (templates precedent)** — dodges the
  built-in/shadowing question, but ACLs possess exactly the scoped
  uniqueness templates lack (#47), and name-addressing matches zones,
  groups, and VLANs. Rejected.
- **Singletons resolve built-ins read-only** — no legacy producer of
  built-in detail (browse shows no fields beyond name/comment); adds a
  special case for zero consumer value. Rejected (404).
- **Built-ins excluded from the collection** — would make the list
  list-mode-consistent ("server-owned only") but the AML editors legitimately
  need the built-ins as match-element targets, as legacy's `get_acl_list`
  includes them. Rejected.
- **Root-level `/acls` collection** — ACLs have no meaning without a server
  context (`get_acl_list`/`get_acl_by_name` take `$serverid` everywhere);
  nothing in the API is root-scoped except truly global resources.
  Rejected.
- **Drop the read level gate to plain `server R`** — legacy leaks names to
  zone editors through the ftype-12 popup, but widening an explicit gate on
  the strength of incidental leakage is worse than matching the menu
  contract; gap tracked under #42. Rejected.
- **Copy the legacy `type>0` delete Update verbatim** — parity, but it
  demonstrably leaves broken ACL bodies behind (#53). Rejected in favour of
  the corrected transaction.
- **Reject inapplicable per-mode fields with 400 instead of normalizing** —
  stricter, but no precedent (the build-row codecs already coerce) and the
  legacy form's equivalent was silent hiding. Rejected.
- **Delete requires reassign when referenced** — safer, but breaks the
  legacy default (popup defaults to resolve-to-none) and the templates
  optional-detach precedent. Rejected.

## Consequences

- New public resources `/servers/{server}/acls`,
  `/servers/{server}/acls/{acl}`, `/servers/{server}/keys`, the
  `AmlElement`/`AclSummary`/`Acl`/`KeySummary` schemas, list filter/sort
  params, two controllers, two repositories, one resolution helper, and the
  ACLs menu in the frontend (`/acls`, `/acls/keys`, `/keys` redirect).
- Server/zone AML consumers finally have reference-data endpoints; host and
  zone/server write semantics unchanged.
- Known debt:
  - joachim162/sauron#53 — `BackEnd::delete_acl` `type>0` hole
    (this API corrects it in the repository).
  - joachim162/sauron#42 — picker endpoints blocked for zone-only editors;
    the ACL read level gate inherits that limitation deliberately.
  - joachim162/sauron#43 — texthandle lowercasing; API stores `name`
    verbatim like VLANs.
  - Key management (keygen-backed CRUD) stays out of the API pending a
    security design.
