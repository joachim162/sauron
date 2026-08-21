# API Design Review — Sauron current design vs Capabilities Canvas observations

> Companion to `docs/api-capabilities-canvas.md`. This review evaluates whether the **current API design** is a *suitable* realization of the identified capabilities, and flags where it diverges from the canvas, the book's design principles, or the AGENTS.md parity/constraints rules.
>
> Reviewed artifacts: `openapi.yaml`, `paths/*.yaml`, `components/schemas.yaml|parameters.yaml|responses.yaml`, `Controller/{Auth,Server,Zone,Host,Net}.pm`, `AuthZ.pm`.
> Verdict: **suitable overall**, with a handful of genuine gaps and several design-decision flag-poles. Details below, grouped by the canvas sections.

---

## 1. Capability coverage — implemented vs canvas (§3 of canvas)

| Canvas capability | Current design | Assessment |
| ----------------- | -------------- | ---------- |
| servers CRUD + list | Full REST CRUD + paginated envelope | ✅ Suitable |
| zones CRUD + list | Full REST CRUD + paginated envelope | ✅ Suitable |
| hosts CRUD + list | Full REST CRUD + copy + move | ✅ Suitable |
| assignable subnets | `GET .../assignable-subnets` (bare array picker) | ⚠️ Intentionally non-envelope; matches stated picker convention |
| networks CRUD + list | Full REST CRUD, `list=top/sub/all/free` + vlan_name enrichment | ✅ Suitable |
| auth (3 flows) | password/session, SSO, PAT-as-`Bearer`, `/auth/config`, `/auth/me` | ✅ Suitable |
| users / groups / acls CRUD | **Not exposed** (BackEnd only) | ❌ Gap — kept for later |
| keys / vlans / templates CRUD | **Not exposed** | ❌ Gap |
| approvals workflow | **Not exposed** | ❌ Gap (largest) |
| history | **Not exposed** | ❌ Gap |
| get free ip / auto-address | Folded into `NewHost.net`, `host-copy.net`, `move.net` | ✅ Good consolidation |

**Conclusion:** every capability the canvas marks *E* is present and well-formed. The gaps are exactly the already-flagged backlog (access control, metadata, approvals, history). No *E* capability is missing.

---

## 2. Suitability against the book's design principles

### 2.1 Focus on proper needs; avoid over-broad operations (§2.6, §9.9)

- **Good:** `copy_host` and `move_host` are separate operations rather than overloaded updates — matches the "don't hide multiple capabilities in one operation" rule.
- **Good:** `new host` auto-IP via `net` is a single cohesive capability, not exposed as a separate "allocate IP" endpoint.
- **Move host is polymorphic** (`ip`/`net` = IP move, `zone` = zone move, discriminated by which field is present). Two distinct capabilities (subnet move vs zone move) share one operation and one `MoveHost` schema. This is the **clearest violation** of §9.9 "hiding multiple capabilities in a single operation" — the request contract silently changes meaning based on which optional field you set. Flag for a conscious decision: split, or document an explicit "mode" discriminator.

### 2.2 User-friendly identifier handling (§8.9, §9.3)

- **Inconsistency confirmed:** servers are addressed by *name* in the path (`{server}`), zones by *name* (`{zone}`), hosts by *hostname*, but the APIs expose `id`/`server_id`/`zone_id` in bodies; networks accept *either* CIDR or netname (`net`). The book (§8.9) wants one naming pattern. This is a *known* tension, not a defect — but it should be a documented decision (name-based paths are arguably more readable for humans). **Flag** as a design-decision to confirm.
- **Host identified by hostname, not id** — canvas already called this out. Acceptable for usability, but note hostname is mutable (rename == implicit identity change); worth a conscious decision.

### 2.3 Error handling & status codes (§4.5, §9.8)

- Read/create/update/delete status mapping is **textbook-correct**: 200/201/204, 400, 401, 403, 404, 409, 500. 409 used for existence conflicts and IP-in-use. Good.
- **Note:** `delete_zone` requires perms `RWS` on the *server* (not zone RW), while `update_zone` requires zone RW. This asymmetry is a parity choice — confirm it's intentional.
- **Error body** is minimal `{error, message}` (machine-kind is absent). The book (§9.8) advocates *machine-readable* problem feedback; current schema has `error` (a code-ish string) + `message`, which is a reasonable lightweight shape. Consider an `Error.code` enum for consumer logic. **Suggestion**, not blocking.

### 2.4 Pagination / filters / sort (§9.6)

- Paginated envelope with `metadata.{pagination,sort,filters}` is exemplary and applied uniformly to every list **except** `assignable-subnets` (intentionally bare, matches documented picker convention). Good.
- **Observation:** no sort/filter *query* parameters are actually consumed by list controllers today (envelope sorts/filters echo static/default values); the zest to accept `q`/sort/filter params (§9.6 "guessable filters") isn't yet realized. Not a defect — the envelope is future-ready. **Flag** as roadmap.

### 2.5 Nullability / data modeling (§OpenAPI pitfalls)

- All nullable fields are declared `nullable: true` — consistent with AGENTS.md. Good.
- Booleans use `JSON::PP::true/false` — consistent. Good.

---

## 3. Concrete defects / genuine gaps found

### 3.1 ❌ NAPTR host type declared but `naptr_l` field is missing
Host type `14` (naptr entry) is advertised in the type descriptions of both `Host.type` and `NewHost.type` (free-form `integer` schema with a documented type list, not an OpenAPI `enum`), but **`HostFields` has no `naptr_l` property**. The CGI form defines `naptr_l` (`Sauron/CGI/Hosts.pm:491–497`, 7-field NAPTR entries). Consequences:
- A consumer reading the type list cannot create a NAPTR host via the API.
- The type list *promises* a capability the schema cannot express.

**Fix:** add `naptr_l` (and its 7 fields: order, pref, flags enum, service, regexp, replacement, comment) to `HostFields`, mirroring the CGI `%naptr_form`. This is a parity requirement per AGENTS.md.

### 3.2 ⚠️ `private_flag` on networks
`NetFields.private_flag` exists in the schema and is writable, but AGENTS.md + BackEnd issue #12 say `add_net` mishandles it and creates deliberately do not send it. The API schema therefore **exposes a field whose semantics are unreliable** on create. **Flag:** either omit `private_flag` from `NewNet` (and only return/allow it on update), or fix BackEnd first. Right now it's a footgun.

### 3.3 ⚠️ Update operations accept `name`/(re)foo that dereference identity?
`UpdateServer`/`UpdateZone` reuse the writable fields including `name`. Updating `name` of a server/zone would silently change the **path identifier** (`{server}`/`{zone}` are name-based). Verify the repository guards against renaming via path-addr resources (or documents that rename is allowed and the new name is returned). **Flag** for confirmation.

### 3.4 ⚠️ Missing schema object for `naptr` / SRV/TLSA details are tight (informational)
SRV, TLSA, SSHFP fields are well-structurered with required sub-fields — good standardization. No action.

---

## 4. Conformance to AGENTS.md architecture rules (repository layer, ADR 0001)

- Controllers decomp-contain `BackEnd` for *reads* (host list/zone/net all through `Repository::*`). `Auth.pm` is the sanctioned exception. ✅
- Name→id resolution via `get_server_id_or_404` / `get_zone_id_or_404` / `get_net_id_or_404` helpers — used consistently. ✅
- Level/perm gating correct & separated: zone/server/host/ip/delhost types via `check_perms`; list allowlists via `visible_*_ids`; superuser gates on net/server create/delete & `free` list. ✅
- `list` param `free` gating matches ADR 0003 + CGI parity; `vlan_name` enrichment gated by `ALEVEL_VLANS`. ✅
- RHF enforced at controller (authz concern), not repository — matches stated design. ✅

**No repository-rule violations found.**

---

## 5. Design decisions to lock (for the upcoming design sessions)

1. **Move-host polymorphism** — split subnet-move vs zone-move into distinct operations, or document an explicit `mode` discriminator (recommend: explicit, to honor §9.9).
2. **Identifier policy** — document that server/zone/host are **name-addressed** in paths while exposing numeric ids in bodies as *read-only* enrichment; state when a rename is allowed.
3. **Update semantics that touch identity** (3.3) — confirm rename handling.
4. **`private_flag`** — decide create-vs-update exposure (3.2).
5. **Sort/filter real params** — whether to wire `q`/sort/filter query params now or defer (envelope already accommodates).
6. **Error body** — adopt a machine-readable `.code`/`.kind` (e.g. reuse `SauronAPI::Exception` kind) for consumer handling of 400/403/409.

---

## 6. Verdict

The current API design is a **suitable, high-quality** realization of the identified capabilities:

- ✅ All canvas-*E* capabilities present, well-formed, correctly authz'd, spec-first, envelope-consistent.
- ✅ Strong parity with legacy CGI on the encoded contract (zone types, reverse zones, catalog, server create rules, RHF, net list modes).
- ✅ Repository layer respected.

Blocking items (fix before relying on it): **NAPTR field gap (3.1)** and **`private_flag` exposure (3.2)**.

Decisions to capture before the next design stage (not blockers): move-host polymorphism, identifier policy + rename, sort/filter params, machine-readable errors (Section 5).

The unimplemented capabilities (users/groups/acls, keys/vlans/templates, approvals, history) remain the principal roadmap — and they are *additive*, so they don't threaten the current design's suitability.
