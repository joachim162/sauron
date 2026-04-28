# Test Infrastructure

The REST API test suite uses `Test::Mojo` with a shared PostgreSQL test database
and a fixture helper module. All tests run inside Docker against the dev database.

## Directory Structure

```
sauron_api/t/
├── config              # Sauron-style config pointing to test DB
├── basic.t             # Original smoke test
├── auth.t              # AuthN tests (login, logout, me)
├── authz.t             # AuthZ tests (permission boundaries)
├── host.t              # Host CRUD tests
└── lib/
    └── SauronAPITest.pm # Fixture helpers + app setup
```

## Architecture

```
Test script (*.t)
  ↓ use SauronAPITest qw(setup_test_app ...)
  ↓
SauronAPITest.pm
  ↓ BEGIN { $Sauron::Sauron::CONF_FILE_PATH = 't' }
  ↓ use Test::Mojo
  ↓ Test::Mojo->new('SauronAPI')  →  SauronAPI::startup()
  ↓                                      ↓ load_config()
  ↓                                      ↓ db_connect()
  ↓                                      ↓ before_dispatch hook
  ↓                                      ↓ OpenAPI plugin
  ↓
  ↓ Provides fixture helpers:
  ↓   create_test_user(), delete_test_user()
  ↓   create_test_server(), delete_test_server()
  ↓   create_test_zone(), delete_test_zone()
  ↓   grant_server_access(), grant_zone_access()
  ↓   make_pat()
Test assertions
  ↓ $t->get_ok(...)->status_is(...)->json_is(...)
```

## Config Loading

`SauronAPI::startup()` calls `Sauron::Sauron::load_config()` which searches for
a file named `config` in `/etc/sauron/`, `/usr/local/etc/sauron/`, etc.

`SauronAPITest.pm` intercepts this by setting `$Sauron::Sauron::CONF_FILE_PATH`
to the absolute path of `t/` before `Test::Mojo->new()` runs:

```perl
BEGIN {
  my $test_dir = dirname(abs_path(__FILE__));
  $Sauron::Sauron::CONF_FILE_PATH = dirname($test_dir);  # → sauron_api/t/
}
```

The `t/config` file is a Perl script that sets global `$main::` variables:

```perl
$DB_DSN = "dbi:Pg:dbname=saurondb;host=postgres;port=5432";
$DB_USER = "sauronuser";
$DB_PASSWORD = "sauronpass";
$SERVER_ID = "testserver";
$PROG_DIR = "/srv/sauron/";
$SAURON_PWD_MODE = 1;
$SAURON_PRIVILEGE_MODE = 0;
```

The DB credentials match Docker Compose's `postgres` service. Tests share
the `saurondb` database—they don't use a separate test database.

### Why absolute path?

Modern Perl (5.26+) removed `.` from `@INC`. `Sauron::Sauron::load_config_file()`
uses `do "$file"` which requires the file to be findable via `@INC`. Setting
`CONF_FILE_PATH` to an absolute path avoids this.

## File Permissions Trap

`load_config_file()` checks `stat($file)[2] & 0022` and dies with "unsafe file
permissions" if the config file is group- or world-writable. The `t/config`
file must be `644` or stricter:

```bash
chmod 644 sauron_api/t/config
```

## Fixture Helpers

`SauronAPITest.pm` provides functions to create and destroy test data.

### User Fixtures

```perl
my $uid = create_test_user(
  username  => 'alice',
  email     => 'alice@example.com',
  password  => 'secret',
  superuser => 0,        # default false
);
delete_test_user($uid);  # cascades to sessions, PATs, user_rights
```

Users are created via `Sauron::BackEnd::add_record('users', ...)` which
bypasses the API entirely. Passwords are hashed using `Sauron::Util::pwd_make()`
with the mode from `t/config` (`$SAURON_PWD_MODE = 1` → Unix crypt).

`delete_test_user()` manually cleans up related rows because the foreign key
constraints on `user_rights` use `ON DELETE SET NULL`, not `CASCADE`:

```perl
db_exec("DELETE FROM user_rights WHERE type=2 AND ref=$user_id");
db_exec("DELETE FROM bff_sessions WHERE user_id=$user_id");
db_exec("DELETE FROM personal_access_tokens WHERE user_id=$user_id");
db_exec("DELETE FROM users WHERE id=$user_id");
```

### Server & Zone Fixtures

```perl
my $sid = create_test_server(name => 'ns1', comment => 'Primary DNS');
my $zid = create_test_zone(server_id => $sid, name => 'example.com');

delete_test_zone($zid);
delete_test_server($sid);
```

### Permission Fixtures

```perl
grant_server_access($uid, $sid, 'R');    # rtype=1, rule='R'
grant_zone_access($uid, $zid, 'RW');      # rtype=2, rule='RW'
```

Inserts directly into `user_rights` with:
- `type=2` (individual user, not group)
- `rtype=1` (server) or `rtype=2` (zone)
- `rule=R/RW/RWS`

### PAT Fixtures

```perl
my $token = make_pat($uid, 'test-token');
# Returns the plain-text token like 'sauron_sk_abc123...'
```

Named `make_pat` to avoid conflicting with `Sauron::BackEnd::create_pat`.

## Test Lifecycle

### Setup

Each test file:
1. Calls `setup_test_app()` once to create the `Test::Mojo` instance
2. Creates shared fixtures (servers, zones, users) at file scope
3. Registers an `END` block for cleanup

### Cleanup

```perl
my (@users, @servers, @zones);
END {
  for my $uid (@users)   { eval { delete_test_user($uid);   }; }
  for my $zid (@zones)   { eval { delete_test_zone($zid);   }; }
  for my $sid (@servers) { eval { delete_test_server($sid); }; }
}
```

The `eval` wrapper ensures cleanup continues even if one deletion fails.
Cleanup runs in reverse dependency order (users → zones → servers).

### Unique Names

All fixture names include `$$` (the PID) to prevent conflicts between
concurrent test runs:

```perl
my $pid = $$;
create_test_server(name => "srv-${pid}-1");
create_test_user(username => "testuser_${pid}");
```

### Residue Handling

If a test dies before cleanup, leftover fixtures remain in the database.
The next test run creates different fixtures (different PID), so there's
no conflict. Periodic `docker compose down -v` resets the database.

## Digest::SHA Name Collision

`Sauron::BackEnd` imports `Digest::SHA qw(sha256_hex)`. The test helper
re-exports it automatically since it `use Sauron::BackEnd`. No direct
import is needed for testing.

## Running Tests

```bash
# Start Docker
docker compose up -d postgres sauron_api

# All tests
docker compose exec sauron_api bash -c "cd /srv/sauron/sauron_api && prove -l t/"

# Single test
docker compose exec sauron_api bash -c "cd /srv/sauron/sauron_api && prove -l t/authz.t"

# Verbose (shows test names and DEBUG output)
docker compose exec sauron_api bash -c "cd /srv/sauron/sauron_api && prove -lv t/host.t"
```

### Pre-requisites

The `personal_access_tokens` table is not part of the standard Sauron schema.
If missing, create it:

```bash
docker compose exec -T postgres psql -U sauronuser -d saurondb < sql/personal_access_tokens.sql
```

## Common Pitfalls

### `db_exec` name conflict

`Sauron::DB` exports `db_exec` by default. `SauronAPITest` imports it
explicitly from `Sauron::DB` rather than redefining it.

### `create_pat` name conflict

`Sauron::BackEnd` exports `create_pat` with a precise signature `($$$)`.
The fixture helper uses `make_pat` to avoid prototype mismatch warnings.

### `Data::Dumper` in controllers

`Server.pm:247` and `Server.pm:328` have `print Dumper(...)` debug statements
that pollute test output with `Wide character in print` warnings. These are
harmless but noisy. Should be removed in production.

### Permission ordering in cleanup

`delete_test_user` must run `DELETE FROM user_rights WHERE type=2 AND ref=$uid`
BEFORE `DELETE FROM users WHERE id=$uid` because `user_rights` has no
`ON DELETE CASCADE` on the `ref` column.

## See Also

- [[Running-the-API]] — Docker setup for test database
- [[Test-Mojo-Guide]] — Test::Mojo API reference and auth testing patterns
- [[Authentication-and-Authorization-Flow]] — How auth methods work
- `sauron_api/t/lib/SauronAPITest.pm` — Fixture helper source
- `sauron_api/t/config` — Test database configuration
