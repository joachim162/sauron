# API AuthN/AuthZ Proposal
#security #authentication #authorization #api #proposal

Proposed architecture for integrating Sauron's existing authorization system with the REST API using **Personal Access Tokens (PAT)**.

## Core Principle

PATs link to existing `users.id` → automatic permission inheritance via `get_permissions()`.

## Database Schema

```sql
CREATE TABLE personal_access_tokens (
    id          SERIAL PRIMARY KEY,
    user_id     INT4 NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash  TEXT UNIQUE NOT NULL,   -- SHA-256 hash of the token
    name        TEXT NOT NULL,          -- e.g., "SaltStack Automation"
    created_at  INT4 DEFAULT extract(epoch from now()),
    expires_at  INT4,                   -- NULL = never expires
    last_used   INT4,
    last_ip     TEXT
);
```

## Authentication Flow

```
Authorization: Bearer <token> → hash lookup → user_id → get_permissions() → stash
```

### OpenAPI Security Scheme

```yaml
components:
  securitySchemes:
    PersonalAccessToken:
      type: http
      scheme: bearer
      bearerFormat: PAT
```

### Global Security

```yaml
security:
  - PersonalAccessToken: []
```

### SauronAPI.pm Implementation

```perl
security => {
    PersonalAccessToken => sub ($c, $definition, $scopes, $cb) {
        my $auth = $c->req->headers->authorization;  # "Bearer sau_abc123..."
        return $c->$cb("Missing Authorization header") unless $auth;
        
        my ($token) = $auth =~ /^Bearer\s+(.+)$/;
        return $c->$cb("Invalid Authorization format") unless $token;
        
        # Verify token against database
        my $user_id = Sauron::BackEnd::verify_pat($token);
        return $c->$cb("Invalid or expired token") unless $user_id;
        
        # Load permissions from existing Sauron system
        my %perms;
        Sauron::BackEnd::get_permissions($user_id, \%perms);
        
        # Stash for controllers to use
        $c->stash(
            api_user_id => $user_id,
            api_perms   => \%perms,
        );
        
        return $c->$cb();  # Success
    }
}
```

### BackEnd.pm Functions

```perl
sub verify_pat($) {
    my($token) = @_;
    my $hash = sha256_hex($token);
    my @q;
    
    db_query("SELECT user_id FROM personal_access_tokens WHERE token_hash = '$hash' AND (expires_at IS NULL OR expires_at > extract(epoch from now()))", \@q);
    return $q[0][0] if (@q > 0);
    return undef;
}

sub create_pat($$$) {
    my($user_id, $name, $rec) = @_;
    my $plain_token = generate_random_token();  # 32-byte hex
    my $hash = sha256_hex($plain_token);
    
    db_exec("INSERT INTO personal_access_tokens (user_id, token_hash, name) VALUES ($user_id, '$hash', '$name')");
    
    $rec->{plain_token} = $plain_token;  # Only time it's returned
    return $hash;
}

sub revoke_pat($$) {
    my($token_id, $user_id) = @_;
    db_exec("DELETE FROM personal_access_tokens WHERE id = $token_id AND user_id = $user_id");
}

sub get_pats($$) {
    my($user_id, $list) = @_;
    db_query("SELECT id, name, created_at, expires_at, last_used, last_ip FROM personal_access_tokens WHERE user_id = $user_id ORDER BY created_at DESC", $list);
}
```

## Controller Usage

After authentication, controllers access stashed data:

```perl
sub update_zone ($self) {
    my $user_id = $self->stash('api_user_id');
    my $perms   = $self->stash('api_perms');
    
    # Check permissions
    my $server_id = $self->param('server');
    unless ($perms->{server}->{$server_id} =~ /RW/) {
        return $self->render(openapi => { error => 'Forbidden' }, status => 403);
    }
    
    # ... rest of controller logic
}
```

## Distinguishing API vs Regular Activity

**Option A (Recommended):** Add `source` column to history
```perl
update_history($user_id, $sid, $type, $action, $info, $ref);
# Extend with source='api' for audit purposes
```

**Option B:** Use negative `sid` values for API sessions
```perl
my $sid = -1;  # API operations use negative SIDs (allowed per BackEnd.pm:4111)
```

## User Self-Service (CGI)

New "Personal Access Tokens" menu item where users can:
- Generate new tokens (shown once, then only hash stored)
- Name tokens for identification
- Revoke tokens
- View last used timestamps

## Permission Model

| User Type | Permissions | How |
|-----------|-------------|-----|
| Regular user | Full CGI + API | `user_rights` table |
| PAT | Inherited from creator | Linked to `user_id` |
| Superuser | Everything | `superuser=t` flag |

## Tradeoffs

| Approach | Pros | Cons |
|----------|------|------|
| Link to existing users | Simple, inherits permissions | Can't have "API-only" users |
| Separate `api_users` table | More flexible | Duplicate permission logic |

**Recommendation:** Link to existing users. Create "system" user type if API-only accounts needed later.

## Open Questions

1. Should PATs have expiration options?
2. Should PATs support permission subsets (more restrictive than creator)?
3. Is rate limiting per PAT needed?

## Related
- [[Database-API-Key-Authentication]] - Original API key concept
- [[Sauron-Core-Authorization-System]] - Permission model details
- [[Sauron-Logging-System]] - History tracking
- [[Authentication-and-Authorization]] - API-level auth flow
