# Sauron Core Authorization System
#security #authorization #sauron-core #back-end

Sauron uses a role-based access control (RBAC) system built into `Sauron::BackEnd` that the REST API can leverage for authorization.

## Database Tables

### users Table (`sql/users.sql`)
Core user accounts with authentication data:
```sql
CREATE TABLE users (
    id          SERIAL PRIMARY KEY,
    username    TEXT NOT NULL,
    password    TEXT,          -- MD5:$salt:$hash or CRYPT:$salt:$hash
    superuser   BOOL DEFAULT false,
    email       TEXT,
    last        INT4,          -- last login time
    ...
);
```

### user_rights Table (`sql/user_rights.sql`)
Permission assignments linking users to resources:
```sql
CREATE TABLE user_rights (
    type    INT,   -- 1=user_group, 2=users
    ref     INT,   -- ptr to users.id or user_groups.id
    rtype   INT,   -- permission type (see below)
    rref    INT,   -- ptr to resource (server, zone, net)
    rule    CHAR(80)  -- R, RW, RWS, or regex
);
```

## Permission Types (rtype)

| rtype | Resource | rule format |
|-------|----------|-------------|
| 0 | Group membership | - |
| 1 | Server | R, RW, RWS |
| 2 | Zone | R, RW, RWS |
| 3 | Net (IP range) | [range_start, range_end] |
| 4 | Hostname mask | regex |
| 5 | IP mask | regex |
| 6 | Authorization level | 0-999 |
| 7 | Expiration limit | days |
| 11 | Delete mask | regex |

## Authorization Levels

Defined in `Sauron/Sauron.pm:102-109`:
```perl
$main::ALEVEL_VLANS = 5;
$main::ALEVEL_ACLS = 5;
$main::ALEVEL_RESERVATIONS = 1;
$main::ALEVEL_PING = 1;
$main::ALEVEL_HISTORY = 1;
```

## Loading Permissions

**Function:** `Sauron::BackEnd::get_permissions($uid, $rec)` (`BackEnd.pm:4004`)

```perl
my %perms;
get_permissions($user_id, \%perms);

# Result structure:
# $perms{server}  = { serverid => "RW", ... };
# $perms{zone}    = { zoneid => "R", ... };
# $perms{net}     = { netid => [start, end], ... };
# $perms{hostname} = [[zoneid, regex], ...];
# $perms{alevel}  = 5;  -- max of all rtype=6 assignments
# $perms{groups}  = "group1,group2";
```

## Checking Permissions

**Function:** `Sauron::CGI::Utils::check_perms($type, $rule, $quiet)` (`CGI/Utils.pm:183`)

```perl
# Check authorization level
check_perms('level', $main::ALEVEL_VLANS);

# Check server access
check_perms('server', 'RW');

# Check zone access
check_perms('zone', 'R');

# Check host permission (with hostname regex)
check_perms('host', 'admin-.*');

# Superuser bypass
return 0 if ($state->{superuser} eq 'yes');
```

## API Integration

To integrate the REST API with Sauron's authorization:

1. **Authentication:** Verify API key against `users` table or dedicated `api_keys` table
2. **Load Permissions:** Call `get_permissions($user_id, \%perms)`
3. **Check Access:** Implement permission checks in controllers using the same logic as `chk_perms()`

Example controller check:
```perl
sub require_server_access($self, $server_name, $required_mode) {
    my $api_user = $self->stash('api_user');
    my %perms;
    
    get_permissions($api_user->{id}, \%perms);
    
    # Superuser bypass
    return 1 if ($api_user->{superuser} eq 't');
    
    my $server_id = get_server_id($server_name);
    my $mode = $perms{server}->{$server_id} // '';
    
    return ($mode =~ /$required_mode/);
}
```

## Related
- [[Database-API-Key-Authentication]] - API key storage proposal
- [[Authentication-and-Authorization]] - API-level auth flow
- [[Sauron-Core-Security-Model]] - Security overview
- [[BackEnd.pm]] - Core module location
