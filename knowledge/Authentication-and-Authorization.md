# Authentication and Authorization
#security #api #authentication #authorization

The Sauron REST API uses an API key-based authentication mechanism and a scope-based authorization method.

## Authentication
Authentication is handled by the `ApiKeyAuth` security scheme defined in the `openapi.yaml` and implemented in `SauronAPI.pm`.

- **Header:** `X-API-KEY`
- **Configuration:** API keys are stored in `sauron_a_p_i.yml`.
- **Validation:** The API checks if the provided key exists in the configuration. (Note: This is moving to a database-backed system, see [[Database-API-Key-Authentication]]).

```perl
# Example sauron_a_p_i.yml
api_keys:
  'sau_7kL9wR2mXpQ4nZ1vB8yT5aC3dE6fG9hJ':
    owner: 'saltstack'
    role: 'admin'
```

## Authorization
The authorization method maps the role associated with an API key to the scopes required by a specific endpoint.

### Scopes in OpenAPI
Endpoints can define required scopes using the `security` property:
```yaml
paths:
  /servers:
    get:
      security:
        - ApiKeyAuth: [admin, read]
```

### Validation Logic
The `security` callback in `SauronAPI.pm` compares the key's role against the required scopes:
```perl
my $user_role = $key_data->{role};
my $is_authorized = grep { $_ eq $user_role } @$scopes;
return $c->$cb("Forbidden: ...") unless $is_authorized;
```

## Best Practices
- **Key Rotation:** API keys should be rotated periodically.
- **Least Privilege:** Assign the minimum required role to each API key.
- **TLS/SSL:** Always serve the API over HTTPS to protect keys in transit.

## Related
- [[API-Entry-Point]]
- [[Framework-Configuration]]
- [[OpenAPI-Core-Concepts]]
