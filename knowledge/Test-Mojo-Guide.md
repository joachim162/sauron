# Test::Mojo for Sauron API Testing

Test::Mojo is the standard testing framework for Mojolicious applications. It provides a fluent, chainable API for testing HTTP requests, JSON responses, headers, and WebSocket connections.

## Basic Setup

```perl
use Mojo::Base -strict;
use Test::More;
use Test::Mojo;

my $t = Test::Mojo->new('SauronAPI');
```

The app class name `'SauronAPI'` maps to `sauron_api/lib/SauronAPI.pm`. Test::Mojo loads the application and creates an embedded server for testing — no need to start a real HTTP server.

## Key Methods for JSON API Testing

### Request Methods
All return `$t` for chaining. Each checks for transport errors automatically.

- `get_ok($url)` — `GET` request
- `post_ok($url => json => {...})` — `POST` with JSON body
- `patch_ok($url => json => {...})` — `PATCH` with JSON body
- `put_ok($url => json => {...})` — `PUT` with JSON body
- `delete_ok($url)` — `DELETE` request

Custom headers are passed as a hashref before the body:
```perl
$t->get_ok('/api/v1/servers' => {Authorization => 'Bearer sau_xxx'})
  ->status_is(200);
```

### Response Assertions

- `status_is($code)` — exact HTTP status match
- `status_isnt($code)` — status must not match
- `json_is('/pointer' => $expected)` — JSON Pointer exact match
- `json_like('/pointer' => qr/.../)` — JSON Pointer regex match
- `json_has('/pointer')` — value exists at pointer
- `json_hasnt('/pointer')` — value does not exist
- `header_is('Name' => 'value')` — exact header match
- `header_like('Name' => qr/.../)` — header regex match
- `header_exists('Name')` — header is present
- `content_type_is('application/json')` — Content-Type exact match

### JSON Pointer Examples

```perl
$t->get_ok('/api/v1/servers')
  ->status_is(200)
  ->json_is('/0/name' => 'ns1.example.com')
  ->json_has('/0/id')
  ->json_like('/0/type' => qr/^(master|slave)$/);
```

## Authentication Testing Strategies

Our API has three auth methods (see [[Authentication-and-Authorization-Flow]]). Test each by setting the appropriate headers/context before the request.

### BearerAuth (PAT)

```perl
$t->get_ok('/api/v1/servers' => {Authorization => 'Bearer sau_testtoken'})
  ->status_is(200);
```

### Proxy Auth (OIDC via Apache)

Simulate the trusted proxy by setting `X-Remote-User` and ensuring the remote IP is trusted. The embedded Test::Mojo server runs on `127.0.0.1` by default, which is in the default trusted list:

```perl
$t->get_ok('/api/v1/servers' => {'X-Remote-User' => 'alice@example.com'})
  ->status_is(200);
```

If testing with custom `PROXY_AUTH_TRUSTED_IPS`, the Test::Mojo server may bind to a different address. Override via `$t->ua->server->url` or set the env var before constructing `$t`.

### Session Cookie Auth

Test::Mojo's user agent has a cookie jar. After a login request, subsequent requests automatically include the session cookie:

```perl
# Login
$t->post_ok('/api/v1/auth/login' => json => {username => 'alice', password => 'secret'})
  ->status_is(200)
  ->json_has('/token');

# Subsequent requests use the cookie automatically
$t->get_ok('/api/v1/servers')
  ->status_is(200);

# Or reset session to test unauthenticated access
$t->reset_session;
$t->get_ok('/api/v1/servers')
  ->status_is(401);
```

## Testing Authorization (403 vs 401)

Use `status_is` to verify both authentication and authorization boundaries:

```perl
# No auth at all → 401
$t->get_ok('/api/v1/servers')
  ->status_is(401)
  ->json_is('/error' => 'Unauthorized');

# Authenticated but no permission → 403
$t->get_ok('/api/v1/servers' => {'X-Remote-User' => 'bob@example.com'})
  ->status_is(403)
  ->json_is('/error' => 'Forbidden');
```

## Transaction Inspection

For custom assertions, access the underlying `Mojo::Transaction::HTTP`:

```perl
$t->get_ok('/api/v1/servers')->status_is(200);
my $json = $t->tx->res->json;
is scalar(@$json), 2, 'two servers returned';
```

## Configuration Override for Tests

Pass a config hashref to `new()` to override application config (e.g., disable OIDC, use test database):

```perl
my $t = Test::Mojo->new('SauronAPI', {
  secrets => ['test-secret'],
  database => { dsn => 'dbi:Pg:dbname=sauron_test' },
});
```

This sets `config_override => 1` automatically, disabling `NotYAMLConfig` plugin so the hashref takes precedence.

## Log Level in Tests

Test::Mojo sets `MOJO_LOG_LEVEL` to `fatal` (silent) unless `HARNESS_IS_VERBOSE` is set. To see logs during debugging:

```bash
HARNESS_IS_VERBOSE=1 prove -l -v t/basic.t
```

Or set it in the test:
```perl
$t->app->log->level('debug');
```

## Running Tests

```bash
# All tests
cd sauron_api && prove -l t/

# Single test with verbose output
prove -l -v t/basic.t

# With debug logging
HARNESS_IS_VERBOSE=1 prove -l -v t/basic.t
```

## Sauron-Specific Testing Considerations

- **Database state**: Tests need a database. The Docker `postgres` service is the easiest target; set `POSTGRES_*` env vars before running tests, or use a test-specific config override.
- **Permissions**: `get_permissions()` in `Sauron::BackEnd` determines access. Create test users with known permission sets in a `t/setup.pl` or test fixture.
- **Proxy trusted IPs**: The default `127.0.0.1,::1` works for Test::Mojo's embedded server. If you override `PROXY_AUTH_TRUSTED_IPS` in tests, ensure it includes `127.0.0.1`.
- **Marker format**: BackEnd returns marker-format arrays. Use `_strip_marker_format()` (from controllers) before JSON assertions, or assert against the raw marker format if testing the controller directly.

## See Also

- [[Authentication-and-Authorization-Flow]] — How authN/authZ work in the API
- [[Running-the-API]] — Docker and local run instructions
- `sauron_api/t/basic.t` — Current minimal test
- `sauron_api/lib/SauronAPI.pm` — App startup, `before_dispatch` hook, auth helpers
- https://docs.mojolicious.org/Test/Mojo — Full upstream documentation
