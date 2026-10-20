# 0013. Administrative user management and legacy parity gaps

Status: Accepted

## Context

Before this change, the REST API exposed read-only `/users` and `/users/{id}`
resources and separate self-service account operations under `/auth/me`.
Administrative account lifecycle and permission management were available through
`adduser`, `moduser`, and `deluser`.

The administrative API covers the user-side functionality of those tools.
Strict CLI parity would also reproduce administrator-lockout hazards, permit
reopening a closed identity, and require a local password even for externally
authenticated accounts. These behaviors are deliberately not all copied.

This ADR records the administrative API's agreed behavior, deliberate CLI
divergences, and the legacy gaps either corrected or explicitly retained.

## Decision

### Scope and authorization

Extend the existing ID-addressed user resources with account creation and
editing, username changes, administrative password resets, locking/unlocking,
closure, and permanent deletion. Include membership in existing user groups
and all 15 rule kinds supported by `moduser` (group membership plus rule kinds
1 through 14). Support listing direct rules and inherited group rules, adding
direct rules, removing individual direct rules, and removing all direct rules.
Inherited rules belong to their groups and are not editable through a user's
rule collection.

All new administrative operations require superuser. Preserve the existing
read policy: listing users requires superuser; users may read their own account.
User-group CRUD and frontend work are outside this implementation's scope.
Self-service operations remain separate from administrative writes.

Include a superuser-only, read-only `GET /user-groups` reference-data endpoint
for discovering existing groups when assigning memberships. Return `id`, `name`,
and nullable `comment` in the standard paginated envelope. This is an explicit
scope extension beyond account resources, not user-group lifecycle or rule
management: there are no group creation, edit, delete, or group-rule writes.

### Permission-rule resources

Manage permission rules through `/users/{id}/rights`, separate from the user
account document. Use typed rule objects with named kinds matching the CLI
vocabulary and kind-specific fields, rather than exposing the overloaded
storage fields `rtype`, `rref`, and `rule`. Examples include
`{kind: server, server_id: 1, mode: RW}`, `{kind: level, value: 50}`,
`{kind: group, group_id: 3}`, and `{kind: rhf, field: dept, required: true}`.
Returned rules include their rule ID and provenance: direct, or inherited from
an identified and named user group.

The rights resource supports listing rules, adding individual direct rules,
deleting individual direct rules by ID, and deleting all direct rules. These
operations, including listing rights, require superuser. Inherited rules are
read-only here; removing a direct rule does not remove access independently
granted by a group. The user's account schema does not accept a replace-all
permission set. Preserve the existing permission evaluator rather than making
its flattened effective-permission result writable.

Reject an exact duplicate direct rule with `409 Conflict`. Distinct rules of
the same kind remain allowed, preserving legacy evaluator behavior. A direct
rule may duplicate an inherited grant because the two have different owners:
removing group membership must not remove the explicit direct grant, and
removing the direct grant must not remove inherited access. Do not treat direct
rules as deny rules or as guaranteed overrides of inherited rules.

The primary workflow is targeted grant/revoke operations, matching `moduser`,
not atomic replacement of a complete account configuration. Multi-request
account-and-rule changes are not one atomic save.

### Account lifecycle

- `POST /users` accepts an optional local password. When supplied, hash it
  using the configured password mode and preserve the API's existing
  password-length safeguards. When omitted, create a passwordless account.
  Do not automatically generate or return a temporary password.
- `POST /users/{id}/close` clears personal details, removes permissions and
  memberships, and disables access while retaining the username and ID for
  history. This is the operation the CLI calls anonymization, not complete
  anonymization of the retained identity or its history.
- Default server and zone selections are navigation preferences, not access
  grants. Creating an account with defaults does not automatically grant read
  access; administrators assign access explicitly through the rights resource
  or user-group membership.
- `DELETE /users/{id}` permanently removes the account.
- Both closure and permanent deletion require a locked or expired target,
  matching the `deluser` precondition.
- Closure is terminal through the API. Closed accounts may only be read or
  permanently deleted. Editing, unlocking, password resets, and permission or
  membership changes on a closed account are rejected with `409 Conflict`.
  Repeated closure also returns `409 Conflict`, matching the CLI rejection of
  an already anonymized account. Locking, unlike closure, is reversible.

### Administrator-lockout protection

Reject administrative changes that lock, expire, close, delete, or demote the
caller's own account. Also reject changes that leave no active superuser
account. Return `409 Conflict` with a specific explanation. The CLI remains
an intentional operational escape hatch; these are API safeguards, not
changes to the legacy tools.

For this safeguard, an active superuser has `superuser=true`, is neither locked
nor closed, and has no expiration or an expiration strictly in the future.
Passwordless accounts qualify; the safeguard does not attempt to verify external
identity-provider access or require an existing PAT. Evaluate this condition at
the time of the administrative change. It prevents immediate lockout, not future
loss of access caused by scheduled expiration or external authentication outages.

### Local-password administration and authentication mode

When `auth.mode` is `oidc`, reject account creation with a supplied local
password and administrative local-password resets with `403 Forbidden`.
Passwordless account creation and other administrative operations remain
available. Local-password provisioning and resets are available in `password`
and `both` modes. This extends the mode gate used by self-service password
changes in ADR 0012 to the new administrative password-setting operations.
It does not change existing login or self-service behavior.

### Account eligibility across authentication methods

Correct the passwordless-account expiration gap in this implementation.
Shared API eligibility checks verify account existence,
lock/closure state, and expiration independently of local-password presence.
Apply these checks to proxy/SSO, session, and PAT authentication and cover all
three paths with expiration tests. A valid external identity, session, or PAT
must not bypass expiration of its owning Sauron account. Nonexpired passwordless
accounts remain eligible for these authentication methods.

This corrects API reliance on the legacy status helper; it does not change the
separate existing `/auth/login` OIDC-mode behavior described below.

### Credential revocation

Locking an account or administratively resetting its local password permanently
revokes all of its existing sessions and personal access tokens. Unlocking does
not restore revoked credentials. Closure likewise revokes credentials; permanent
deletion removes them with the account. Credential revocation must be committed
atomically with the corresponding account change.

Administrative password resets are allowed on locked accounts and preserve the
lock. The administrator can replace a compromised password before explicitly
restoring access. Closed accounts remain ineligible for password resets.

Permission changes alone do not revoke credentials: the API reloads permissions
on each request, so subsequent requests use the updated access rules.

### Audit history

Every successful administrative mutation must record an entry in Sauron's
existing history mechanism, identifying the acting administrator, target account,
action, and relevant changes, including permission grants and removals. Record
password resets as events without passwords or password hashes; never record
session tokens or PAT secrets. Commit the audit entry and mutation atomically;
an audit-write failure rolls back the change. Failed requests must not produce
successful-change history entries. Read-only operations do not create mutation
history entries.

### Transactions and BackEnd integration

Serialize administrative mutations with a transaction-scoped advisory lock and
recheck the acting account's active-superuser eligibility inside that transaction.
Lock the target row before changes. This prevents concurrent API administrators
from applying changes using stale privileges and makes duplicate checks and
last-administrator checks part of the same serialized mutation boundary. The
legacy CLI does not participate in this lock and remains an operational escape
hatch, not a source of the API's concurrency guarantees.

Use unchanged BackEnd helpers for account creation and updates, rights insertion,
and history insertion. All API-specific changes belong in the repository layer;
`Sauron/BackEnd.pm` must remain unchanged. Parameterized repository SQL handles
reads, credential revocation, rights removal, and account closure/deletion.
The repository preserves the legacy closure field resets and writes its own
history entry through the existing history helper, using the authenticated
administrator's ID and username rather than the service process's OS login.
Cleanup, account mutation, and history insertion remain in one transaction.
The legacy `delete_user` helper and all CLI callers remain untouched.

User writes use separate request schemas without injected update defaults;
username and email are mutable, unlike stale descriptions in the former
read-only response schema. User responses also expose nullable `last_login_from`
to retain the CLI's last-login source information.

## Accepted divergences and legacy gaps

| Concern | CLI behavior | Administrative API decision | Reason |
|---|---|---|---|
| Administrator self-lockout | No protection against disabling or demoting the operator's own account | Reject with 409 | Avoid accidentally destroying the operator's administrative access |
| Last active superuser | No last-administrator safeguard | Reject changes leaving no active superuser | Preserve administrative recovery through the API |
| Closure versus deletion | `deluser` defaults to anonymization; `--delete` removes the record | Explicit `POST .../close`; `DELETE` always removes the record | Make retention versus permanent removal unambiguous |
| Anonymization terminology | Retains username and ID while calling the operation anonymization | Call it account closure and document retained identity | Do not imply complete anonymization |
| Passwordless creation | `adduser` prompts for a password and offers a generated default | Omitted password creates an account without a local password; no generated credential | Support proxy/SSO provisioning without a password-delivery workflow |
| Reopening closed accounts | `moduser --unlock` strips `LOCKED:` even from `LOCKED:REMOVED`; a later password reset can restore usability | Closed accounts are immutable except for permanent deletion | Keep historical identities terminal; use reversible locking for suspension |
| Credentials after locking or administrative password reset | `moduser` changes the password field without deleting existing sessions or PATs; old PATs can become usable again after unlocking | Permanently revoke all existing sessions and PATs on either operation | Prevent old credentials from surviving a security intervention |
| Password reset on a locked account | `moduser --passwd` refuses locked accounts | Allow an administrative reset while preserving the lock | Replace compromised credentials without briefly reactivating the account |
| Password administration in OIDC mode | CLI password operations are not governed by the API's `auth.mode` | Reject supplied passwords on creation and administrative resets in `oidc` mode with 403 | Keep new password-setting operations consistent with the self-service mode gate |
| Initial read access from defaults | `adduser` grants server and zone R when both defaults are supplied for a non-superuser without an initial user group | Defaults never implicitly grant access; use explicit direct rules or group membership | Keep navigation preferences separate from authorization |
| Exact duplicate direct rules | CLI and database allow redundant rows | Reject exact duplicate direct rules with 409; overlapping inherited grants remain allowed | Avoid redundant rows while preserving independent ownership of direct and inherited grants |
| Administrative audit coverage | CLI history covers creation, closure/deletion, and membership changes but omits many other mutations | Audit every successful administrative mutation atomically with the change, excluding credential material | Provide complete administrative accountability and avoid unaudited commits |
| Invalid permission patterns and storage bounds | CLI regex rules are not compiled before insertion; overlong values reach the CHAR(80) database limit | Reject invalid Perl regexes and values longer than 80 characters with 400 | Avoid installing unusable rules and surface storage constraints as validation errors |

## Existing permission-evaluation gaps

`BackEnd::get_permissions` combines direct and inherited rules using a UNION
ordered only by rule kind. For server and zone grants it assigns each rule to
the same target-keyed hash, so different modes for one target overwrite one
another without defined direct-versus-inherited precedence. Some other rule
kinds also overwrite earlier values, while authorization levels take the maximum
and masks accumulate. This API preserves the existing evaluator; it does not
promise that a direct R rule restricts an inherited RW grant or that direct
rules override inherited ones. Exposing provenance and rejecting exact direct
duplicates does not resolve this legacy ambiguity.

## Existing authentication gaps

`Controller/Auth.pm::login` currently verifies the database password without
checking `auth.mode`. Consequently, `auth.mode=oidc` does not itself prevent
password login for an account that already has a local password. This behavior
is also reflected in ADR 0012's description of `/auth/login`. The new
administrative password gate does not fix that existing login behavior; changing
it requires a separate explicit decision and authentication tests. Do not infer
that an OIDC deployment has disabled password login merely because new password
administration is gated.

`BackEnd::get_user_status` returns `-1` immediately when the stored password is
empty, before evaluating expiration or the superuser flag. Before this change,
API proxy, session, and PAT authentication looked for `E` or `L` in that result,
so an expired passwordless account could escape the expiration check. The API
now checks eligibility independently in `Repository::User::user_is_active`,
with proxy, session, and PAT coverage. The active-superuser safeguard likewise
does not rely on the legacy status string. The legacy helper's early-return
behavior remains unchanged for other callers; the API bypasses the faulty
assumption rather than requiring a local password.

## Alternatives considered

- Copy CLI behavior exactly, including closure as the default delete behavior,
  mandatory local passwords, and no administrator-lockout safeguards. Rejected
  because accidental loss of access and ambiguous destructive operations are
  especially hazardous for remote clients.
- Permit reopening closed accounts. Rejected because closure has already
  removed personal details and permissions; it is not a reversible suspension.
- Automatically generate temporary passwords. Rejected because this would
  require a credential-delivery workflow that the API does not otherwise have.
- Embed a writable complete direct-rule set in `/users/{id}`. This would support
  atomic account-and-permission saves, declarative provisioning, and fewer
  requests, and would follow existing embedded-array editing patterns. Rejected
  in favor of targeted grant/revoke operations: replace-all writes risk losing
  concurrent grants without conditional-write protection, require differential
  auditing and rule-ID preservation, and complicate the existing self-readable
  account representation. A separate rights resource costs more requests and
  client orchestration but makes the CLI's individual-rule workflow explicit.

## Consequences

- CLI parity is the default behavioral reference, with the explicit exceptions
  above. The legacy tools are unchanged and remain available for recovery.
- Clients must choose closure or permanent deletion explicitly, and cannot
  reactivate a closed identity through the API.
- A passwordless account cannot use password login; it may authenticate through
  a configured external identity provider or an issued personal access token.
- Implementation and controller-parity tests must enforce the lifecycle,
  lockout, and credential-revocation invariants, rather than relying on
  permissive BackEnd write helpers.
- ADR 0012 continues to govern existing password authentication and self-service
  password changes. This ADR adds a mode gate for new administrative
  password-setting operations without changing those existing behaviors.
