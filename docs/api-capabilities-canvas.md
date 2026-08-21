# Sauron API Capabilities Canvas & Operations

> Method source: Arnaud Lauret, *The Design of Web APIs* (2nd ed.), Ch. 2 "Identifying API capabilities" and Ch. 3 "Observing operations from the REST angle".
> Scope: Sauron DNS/DHCP management system. This document is the *capabilities* view — it deliberately defers programming-interface decisions (paths, methods, status codes, OpenAPI) to later design decisions.

## How to read this

The canvas follows the book's capability-identification workflow:

1. **Users** — who is the API for (the people/actors, not the UI).
2. **Use cases** — what users need to achieve (from the legacy CGI menu: the behavioral source of truth).
3. **Steps** — each use case decomposed into atomic steps.
4. **Inputs & success outcomes** — per step.
5. **Alternative & failure paths** — per step.
6. **Versatile operations** — the refined, deduplicated set of things the API does (consumer-neutral, provider-perspective-free).
7. **Pivoted canvas / REST angle** (Ch. 3) — reorganize operations into resources × their actions, with each action's inputs & outputs.

Dedup slice: several CGI screens map to the same underlying capability. Where that happens the canvas names one versatile operation.

---

## 1. Users (actors)

| Actor | Description | Notes |
| ----- | ----------- | ----- |
| **admin** | Full control; superuser above role hierarchy | Manages users, groups, ACLs, approval workflow, keys, config |
| **operator** | Day-to-day DNS/DHCP management within permitted servers/zones | Creates edits hosts, zones, networks, servers; views history |
| **approver** | Reviews and approves pending changes | Only where approvals enabled |
| **self-service end user** | Inputs/edits only their own host data where allowed | "restricted host/user" mode |
| **API consumer / automation** | Programmatic clients (PAT-authenticated), e.g. provisioning | Same operations, different auth path; batch/pagination consumers |

Cross-cutting: **the frontend** is itself a consumer of this API (parity with legacy CGI), but the canvas captures what any consumer needs — not UI screens.

---

## 2. Use cases → steps → operations

Each row: **use case** (what a user wants to achieve) → **steps** → **inputs / success outcome** → **capability (operation)**.

### 2.1 Authentication & session

| Use case | Steps | Inputs → Success outcome | Operation |
| -------- | ----- | ------------------------ | --------- |
| Sign in with password | Verify credentials; open session | email+password → session established | `authenticate (password)` |
| Sign in via SSO/OIDC | Proxy-intercepted OIDC flow; set session | (proxy) → session established | `authenticate (SSO)` |
| Sign in with PAT | Validate bearer token | token → identity resolved | `authenticate (token)` |
| Discover how to sign in | Return configured auth mode | (none) → auth mode + sso url | `read auth config` |
| Learn who I am | Resolve identity + perms | (none) → user + permissions | `read current user` |
| End session | Invalidate session/cookie | (none) → session ended | `log out` |

*Failure paths:* bad password (401), expired/revoked token (401), missing permission on a downstream operation (403).

### 2.2 Servers

| Use case | Steps | Inputs → Success outcome | Operation |
| -------- | ----- | ------------------------ | --------- |
| See all servers I may manage | List (permission-filtered, paginated) | page/per_page → server list | `list servers` |
| Add a server | Create | name+hostaddr+directory → server created | `create server` |
| Inspect a server | Read one | server id → server detail | `read server` |
| Change a server | Update fields | server id + fields → updated | `update server` |
| Remove a server | Delete (cascades deps) | server id → deleted | `delete server` |
| Pick assignable subnets | List subnets of a server available for host IPs | server id → subnet list | `list assignable subnets` |

### 2.3 Zones

| Use case | Steps | Inputs → Success outcome | Operation |
| -------- | ----- | ------------------------ | --------- |
| See zones of a server (visible) | List (permission-filtered, paginated) | server id + page → zone list | `list zones` |
| Add a zone | Create | server id + type(M/S/H/F/C/A)+name(+reverse/catalog apply) → zone created | `create zone` |
| Inspect a zone | Read one | server id + zone id → zone detail | `read zone` |
| Change a zone | Update | server id + zone id + fields → updated | `update zone` |
| Remove a zone | Delete (cascades) | server id + zone id → deleted | `delete zone` |
| Clone a zone | Copy zone + records | from zone → new zone with copies | `copy zone` |

*Special cases (from CGI parity facts):* reverse zones are master-only and always arpa-transformed from CIDR; catalog zones get `ttl=0, minimum=0` (RFC 9432).

### 2.4 Hosts

| Use case | Steps | Inputs → Success outcome | Operation |
| -------- | ----- | ------------------------ | --------- |
| See hosts in a zone | List (paginated, marker-format fields decoded) | server+zone → host list | `list hosts` |
| Add a host | Create (type-1 requires IP; RHF enforced) | server+zone + host data (+IP) → host created | `create host` |
| Inspect a host | Read one + network settings | server+zone+hostname → host detail | `read host` |
| Change a host | Update (RHF enforced) | server+zone+hostname + fields → updated | `update host` |
| Remove a host | Delete | server+zone+hostname → deleted | `delete host` |
| Copy a host | Duplicate host incl. records/IP policy | host + new names → copy created | `copy host` |
| Move a host | Move host between zones | host + target zone → moved | `move host` |
| Auto-allocate IP | Suggest/assign next free IP per net policy | net + policy → ip | `get free ip` (supporting) |

*RHF (Required Host Fields):* enforced on create and update; is a *constraint*, not a separate operation.

### 2.5 Networks

| Use case | Steps | Inputs → Success outcome | Operation |
| -------- | ----- | ------------------------ | --------- |
| Browse networks | List by mode (top/sub/all/free) with pagination; `free` gated by alevel | server id + list mode + page → net list | `list networks` |
| Add a network | Create | server id + network data → net created | `create network` |
| Inspect a network | Read one | server id + net id → net detail | `read network` |
| Change a network | Update | server id + net id + fields → updated | `update network` |
| Remove a network | Delete | server id + net id → deleted | `delete network` |

### 2.6 Users, Groups, ACLs (access control)

| Use case | Steps | Inputs → Success outcome | Operation |
| -------- | ----- | ------------------------ | --------- |
| Manage users | CRUD + status (enable/disable) + change password | user data → user record | `create/read/update/delete user` |
| Manage groups | CRUD + members + dept + apply perm | group data → group record | `create/read/update/delete group` |
| Manage ACLs | CRUD + rule/level structure | acl data → acl record | `create/read/update/delete acl` |
| Read permissions for a user | Resolve effective perms (RHF, hashes) | user → permissions | `read user permissions` |

### 2.7 Keys, VLANs, Templates (network metadata)

| Use case | Steps | Inputs → Success outcome | Operation |
| -------- | ----- | ------------------------ | --------- |
| Manage TSIG/DNS keys | CRUD | key data → key record | `create/read/update/delete key` |
| Manage VLANs | CRUD (name + vlan no) | vlan data → vlan record | `create/read/update/delete vlan` |
| Manage templates (misc/hinfo/wks/mx) | CRUD per template type | template data → template record | `create/read/update/delete template` |

### 2.8 Approvals & change workflow

| Use case | Steps | Inputs → Success outcome | Operation |
| -------- | ----- | ------------------------ | --------- |
| Submit pending change | Record proposed change + diff of affected records | change proposal → pending approval | `submit change for approval` |
| Review pending changes | List pending, view diff of what would change | (none) → pending list + diffs | `list pending approvals` / `read change diff` |
| Accept a pending change | Commit the diff; close approval | approval + accept → change applied | `approve change` |
| Reject a pending change | Discard; close approval | approval + reject → change discarded | `reject change` |

Critical framing: approvals is the largest unimplemented surface (CGI ≈1,462 lines). It is a *change-management* capability distinct from plain CRUD and must be designed as such, not bolted onto host/zone/network update operations.

---

## 3. Consolidated capability inventory

Shows **current API coverage** vs **capability needed**. (E = exposed, R = partially/reference only, N = not exposed.)

| Capability | Group | Status | Notes |
| ---------- | ----- | ------ | ----- |
| list servers / create / read / update / delete | Servers | E | `/servers` |
| list zones / create / read / update / delete / copy | Zones | E (copy N) | copy exists in BackEnd only |
| list hosts / create / read / update / delete / copy / move | Hosts | E | copy+move present |
| list networks / create / read / update / delete | Networks | E | |
| list assignable subnets | Networks | E | unpaginated bare array (picker) |
| authenticate (password / SSO / token) | Auth | E | 3 coexisting flows |
| read current user (+ permissions.rhf) | Auth | E | |
| auth config / log out | Auth | E | |
| users CRUD + status + password | Access control | **N** | BackEnd only (login/auth reads user + perms) |
| groups CRUD + members + perms | Access control | **N** | |
| acls CRUD | Access control | **N** | |
| read user permissions | Access control | R | Partial (rhf in `/auth/me`);
| keys CRUD | Metadata | **N** | |
| vlans CRUD | Metadata | **N** | |
| templates (hinfo/wks/mx/printer) CRUD | Metadata | **N** | |
| approvals: submit / list / diff / approve / reject | Change mgmt | **N** | largest gap |
| get free ip / auto-address suggestion | Hosts | **N** | supporting, BackEnd only |
| history (host/zone/server/session) | Observability | **N** | BackEnd only |

---

## 4. Ch. 3 — Observing the canvas from the REST angle

This is the **pivoted** view the book calls for in §3.2–3.4: re-read the capability list (§2–3) not as operations but as **resources with relations**, then for each resource list its **actions** with each action's **inputs and success/failure outputs**. Programming-interface specifics (paths, methods, status codes, OpenAPI) are still deferred — this is the observation layer that feeds them.

### 4.1 Resources and their relations (§3.3)

A resource is the *subject of actions*: the thing a user manipulates. Identified by re-reading each use case's "success outcome".

| Resource | Identified from | Relations |
| -------- | --------------- | --------- |
| **Server** | "server created/updated/deleted", "see servers I manage" | parent of Zone, Network; parent of Host (via zone) |
| **Zone** | "zone created", "see zones of a server" | child of Server; parent of Host; may be in a Catalog |
| **Host** | "host created/updated/moved/copied" | child of Zone; holds IPs (alias to Network); holds records (alias to record-type sub-resources) |
| **IP assignment** | "change a host's IP", "move host to subnet" | child of Host; child of Network (net policy) |
| **Network** | "network created", "browse networks", "assignable subnets" | child of Server; addresses Hosts; linked to VLAN, Key |
| **User** | "manage users" (backlog) | member of Group; subject of ACL; owner of PAT/session |
| **Group** | "manage groups" (backlog) | member of Server/Zone/ACL rules; holds Permissions |
| **ACL** | "manage ACLs, levels, rules" (backlog) | referenceable from Zone/Server/Network ACL fields |
| **Key / VLAN / Template** | "manage keys/vlans/templates" (backlog) | referenced by Network (vlan), Zone/Server ACL fields (key), Host (template) |
| **Approval** | "approval workflow" (backlog) | captures a proposed change over Server/Zone/Host/Network; holds a recorded diff |
| **Session / PAT** | "sign in / end session" | owned by User |

Relations recap (verb phrase): a **Server** *owns* **Zones** and **Networks**; a **Zone** *owns* **Hosts**; a **Host** *owns* **IP assignments** and *references* record sub-resources; a **Network** *governs* IP assignments and *references* **VLAN/Key**; a **User** *has* **Groups**, **ACLs**, **Sessions/PATs**; an **Approval** *targets* a Server/Zone/Host/Network.

*Design observation carried forward:* host addresses are identified by **both** hostname (in path) and numeric id (in body) — the identifier-pattern question (book §8.9) is most acute here and is flagged in §5.

### 4.2 Pivoted canvas: resources × actions (§3.2)

Each cell lists the **actions** a resource supports. "C/R/U/D" = create/read/update/delete. This is the pivot: rows are now resources (not operations).

| Resource | Actions (from canvas operations) |
| -------- | -------------------------------- |
| **Server** | C (add server), R (list servers, read server), U (update server), D (delete server), **List assignable subnets** |
| **Zone** | C (create zone), R (list zones, read zone), U (update zone), D (delete zone), **Copy zone*** |
| **Host** | C (add host), R (list hosts, read host), U (update host), D (delete host), **Copy host**, **Move host** (subnet), **Move host** (zone) |
| **IP assignment** | *manage as part of host C/U/D*; **Auto-assign IP** (supporting) |
| **Network** | C (add net), R (list nets, browse nets), U (update net), D (delete net) |
| **User*** | C/R/U/D, **set status** (enable/disable), **change password** |
| **Group*** | C/R/U/D, **manage members**, **apply permissions** |
| **ACL*** | C/R/U/D |
| **Key / VLAN / Template*** | C/R/U/D each |
| **Approval*** | **submit change**, R (list pending, read diff), **approve**, **reject** |
| **Session / PAT*** | C (create/login), **destroy** (logout/revoke), R (current user/me) |

`*` = backlog capability (not yet in the API).

**Explicitly non-resource (constraints, not actions):** Required Host Fields (**RHF**) — a validation rule on Host create/update, not a manipulable thing. Catalog-zone / reverse-zone transforms — behavior baked into Zone create.

### 4.3 Actions with inputs and outputs (§3.4)

For each action, its **inputs** (what the consumer must supply) and **outputs** (success case, plus failure cases). Success outputs are the resource representation; failures are the error cases the consumer must handle. Current-api status noted alongside.

#### Server

| Action | Inputs | Outputs (success) | Failures |
| ------ | ------ | ----------------- | -------- |
| Create server | name, hostaddr, directory (+ optional fields) | 201 + Server | invalid data, duplicate name, forbidden |
| List servers | (page/per_page) | 200 + Server list | unauthorized |
| Read server | server id/name | 200 + Server | not found, forbidden |
| Update server | server id/name + fields | 200 + Server | invalid, not found, forbidden |
| Delete server | server id/name | 204 | not found, forbidden (superuser) |
| List assignable subnets | server id/name | 200 + subnet list | not found, forbidden |

#### Zone

| Action | Inputs | Outputs (success) | Failures |
| ------ | ------ | ----------------- | -------- |
| Create zone | server + name, type(M/S/H/F/C/A), reverse?/catalog? | 201 + Zone | invalid, duplicate, forbidden |
| List zones | server + page/per_page | 200 + Zone list | not found, forbidden |
| Read zone | server + zone id/name | 200 + Zone | not found, forbidden |
| Update zone | server + zone + fields | 200 + Zone | invalid, not found, forbidden |
| Delete zone | server + zone | 204 | not found, forbidden (RWS) |
| Copy zone* | source zone → target name | 201 + Zone | invalid, duplicate, forbidden |

#### Host

| Action | Inputs | Outputs (success) | Failures |
| ------ | ------ | ----------------- | -------- |
| Create host | server + zone + hostname, type, (net|ips), type-valid fields | 201 + Host | invalid, RHF missing, duplicate, forbidden, ip denied |
| List hosts | server + zone + page/per_page | 200 + Host list | not found, forbidden |
| Read host | server + zone + hostname | 200 + Host | not found, forbidden |
| Update host | server + zone + hostname + fields | 200 + Host | invalid, RHF missing, not found, forbidden |
| Delete host | server + zone + hostname | 204 | not found, forbidden (delhost) |
| Copy host | server + zone + source hostname + overrides | 201 + Host | invalid, duplicate, forbidden, ip denied |
| Move host (subnet) | server + zone + hostname + (ip\|net) | 200 + Host | ip in use, not found, forbidden, ip denied |
| Move host (zone) | server + zone + hostname + target zone | 200 + Host | target invalid, not found, forbidden |
| Auto-assign IP | network + policy | 200 + IP | none free, forbidden |

#### Network

| Action | Inputs | Outputs (success) | Failures |
| ------ | ------ | ----------------- | -------- |
| Create network | server + netname, name, net (+ range/ip_policy) | 201 + Network | invalid, duplicate, forbidden (superuser) |
| List networks | server + list=top/sub/all/free + page/per_page | 200 + Network list | not found, forbidden |
| Read network | server + net id/CIDR | 200 + Network | not found, forbidden |
| Update network | server + net + fields | 200 + Network | invalid, not found, forbidden (superuser) |
| Delete network | server + net | 204 | not found, forbidden (superuser) |

#### Backlog resources (capsule, same four-form)

| Resource | Action capsule |
| -------- | -------------- |
| User | C/R/U/D; set status; change password — inputs: user data; outputs: 200/201 + User; failures: invalid, duplicate, forbidden, locked/expired on login |
| Group | C/R/U/D; manage members; apply perms — inputs: group data + member/perm changes; outputs + Group; failures: invalid, not found, forbidden |
| ACL | C/R/U/D — inputs: acl + levels/rules; outputs + ACL; failures: invalid, duplicate, forbidden |
| Key/VLAN/Template | C/R/U/D — inputs: entry data; outputs + entry; failures: invalid, duplicate, forbidden |
| Approval | submit (proposal+diff), list pending (200 + list), read diff, approve (200, applies diff), reject (200, discards) — failures: no-op on already-decided, forbidden, invalid diff |

---

## 5. Open design decisions surfaced (for later API-design sessions)

1. **Resource identifier consistency** — name vs id per resource; the book (§8.9) recommends one naming pattern.
2. **Approval modeling** — is approval a resource with states (pending/accepted/rejected), or an action? The diff-retrieval step suggests a stateful resource.
3. **Auto-IP allocation** — expose as an operation or fold into host create (type-1 requires IP)?
4. **Repositories for unimplemented domains** — per ADR 0001, new read/write logic goes through repositories, not BackEnd; this canvases the backlog.
5. **Granularity of "copy/move host"** — are these separate operations or an update with modifiers? The book warns against hiding multiple capabilities in one operation (§9.9). The pivot (§4.2) surfaces that **move host (subnet)** and **move host (zone)** are two distinct actions sharing one capability slot — confirm whether they stay one operation or split (carried into the design review as the top decision).
6. **History as a cross-cutting capability** — read-only; whether it is per-resource or a distinct resource.

---

## 6. Change-management note

The three "RHF" concepts (required host fields) are *validation constraints* enforced on `create host` / `update host`, not independent operations. They belong in the input/output data models, not the capability list — keeping the canvas aligned with the book's "focus on proper needs" (§2.6) and "avoid hiding multiple capabilities" (§9.9) guidance.
